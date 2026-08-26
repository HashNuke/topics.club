defmodule Ircpipe.Irc.Session do
  use GenServer

  import Ecto.Query

  require Logger

  alias Ircpipe.Chat
  alias Ircpipe.Irc.CommandRegistry
  alias Ircpipe.Irc.CommandResult
  alias Ircpipe.Irc.Identifier
  alias Ircpipe.Irc.Session.PendingEchoes
  alias Ircpipe.Repo
  alias Ircpipe.Chat.{ChannelMembership, ServerConnection}
  alias Ircpipe.Accounts.User
  alias Ircxd.Message
  alias Ircxd.Client.{Event, Info}
  alias Ircxd.ISupport

  @channel_list_timeout 10_000
  @command_grace_timeout 300
  @command_timeout 15_000
  @isupport_settle_timeout 100

  def child_spec(%ServerConnection{} = connection) do
    %{
      id: {__MODULE__, connection.user_id, connection.id},
      start: {__MODULE__, :start_link, [connection]},
      restart: :transient
    }
  end

  def start_link(%ServerConnection{} = connection) do
    GenServer.start_link(__MODULE__, connection, name: via(connection))
  end

  def join(%ServerConnection{} = connection, channel) do
    GenServer.call(via(connection), {:join, channel})
  end

  def request_join(%ServerConnection{} = connection, %User{} = user, channel) do
    GenServer.call(via(connection), {:request_join, user, channel})
  end

  def list_channels(%ServerConnection{} = connection) do
    GenServer.call(via(connection), :list_channels, @channel_list_timeout + 1_000)
  end

  def say(%ServerConnection{} = connection, channel, body) do
    GenServer.call(via(connection), {:say, channel, body})
  end

  def action(%ServerConnection{} = connection, channel, body) do
    GenServer.call(via(connection), {:action, channel, body})
  end

  def privmsg_thread(%ServerConnection{} = connection, thread_id, body) do
    GenServer.call(via(connection), {:privmsg_thread, thread_id, body})
  end

  def nick(%ServerConnection{} = connection, nick) do
    GenServer.call(via(connection), {:nick, nick})
  end

  def topic(%ServerConnection{} = connection, channel, topic) do
    GenServer.call(via(connection), {:topic, channel, topic})
  end

  def part(%ServerConnection{} = connection, channel, reason \\ "") do
    GenServer.call(via(connection), {:part, channel, reason})
  end

  def quit(%ServerConnection{} = connection, reason \\ "leaving") do
    GenServer.call(via(connection), {:quit, reason})
  end

  def connection_info(%ServerConnection{} = connection) do
    GenServer.call(via(connection), :connection_info)
  end

  def status(%ServerConnection{} = connection) do
    case Registry.lookup(Ircpipe.Irc.SessionRegistry, {connection.user_id, connection.id}) do
      [] ->
        "disconnected"

      [{_pid, _value}] ->
        case connection_info(connection) do
          {:ok, %Info{registered?: true}} -> "connected"
          _other -> "connecting"
        end
    end
  catch
    :exit, _reason -> "disconnected"
  end

  def execute(%ServerConnection{} = connection, intent, command_id, buffer_id) do
    GenServer.call(via(connection), {:execute, intent, command_id, buffer_id})
  end

  def via(%ServerConnection{user_id: user_id, id: id}) do
    {:via, Registry, {Ircpipe.Irc.SessionRegistry, {user_id, id}}}
  end

  @impl true
  def init(%ServerConnection{} = connection) do
    send(self(), :connect)

    {:ok,
     %{
       connection: connection,
       client: nil,
       registered?: false,
       pending_joins: persisted_channels(connection),
       joined_channels: MapSet.new(),
       names_buffers: %{},
       pending_echoes: PendingEchoes.new(),
       pending_commands: %{},
       ignored_event_logs: %{},
       client_info: nil,
       isupport_received?: false,
       isupport_seen?: false,
       registration_boundary_reached?: false,
       join_validation_ready?: false,
       joins_flushed?: false,
       join_flush_timer: nil,
       sent_joins: MapSet.new(),
       channel_list_request: nil
     }}
  end

  @impl true
  def handle_info(:connect, state) do
    connection = state.connection
    record_server_line(connection, "Connecting to #{connection.host}:#{connection.port}.")
    update_status(connection, "connecting")

    opts = [
      host: connection.host,
      port: connection.port,
      tls: connection.use_tls,
      nick: connection.nickname,
      username: connection.username || connection.nickname,
      realname: connection.realname || connection.nickname,
      caps: [
        "server-time",
        "echo-message",
        "multi-prefix",
        "userhost-in-names",
        "message-tags",
        "batch",
        "labeled-response"
      ],
      events: :envelope,
      notify: self()
    ]

    opts =
      if present?(connection.server_password) do
        Keyword.put(opts, :password, connection.server_password)
      else
        opts
      end

    opts =
      if present?(connection.sasl_username) and present?(connection.sasl_password) do
        Keyword.put(opts, :sasl, {:plain, connection.sasl_username, connection.sasl_password})
      else
        opts
      end

    case Ircxd.Client.start_link(opts) do
      {:ok, client} ->
        {:noreply, %{state | client: client}}

      {:error, reason} ->
        Logger.warning(
          "IRC connection failed for #{connection.host}:#{connection.port}: #{inspect(reason)}"
        )

        record_server_line(
          connection,
          "Connection to #{connection.host}:#{connection.port} failed: #{inspect(reason)}.",
          "error"
        )

        update_status(connection, "errored")
        {:stop, reason, state}
    end
  end

  def handle_info({:ircxd, %Event{} = event}, state) do
    suppress_legacy? = suppress_correlated_legacy_output?(state, event)

    state =
      state
      |> maybe_refresh_client_info(event.name)
      |> process_command_event(event)
      |> reconcile_command_membership_event(event)

    cond do
      membership_failure_event?(event) ->
        maybe_record_membership_failure(event, state)
        {:noreply, state}

      suppress_legacy? ->
        {:noreply, state}

      true ->
        handle_info({:ircxd, event.legacy}, state)
    end
  end

  def handle_info({:ircxd, :registered}, state) do
    {:ok, updated} = update_status(state.connection, "connected")
    record_server_line(updated, "Connected to #{updated.host}.")

    {:noreply,
     state
     |> Map.put(:connection, updated)
     |> Map.put(:registered?, true)
     |> refresh_client_info()
     |> schedule_join_flush()}
  end

  def handle_info({:ircxd, {:connect_error, reason}}, state) do
    Logger.warning("IRC connection error for #{state.connection.host}: #{inspect(reason)}")

    record_server_line(
      state.connection,
      "Connection error for #{state.connection.host}: #{inspect(reason)}.",
      "error"
    )

    update_status(state.connection, "errored")
    {:noreply, state}
  end

  def handle_info({:ircxd, :disconnected}, state) do
    record_server_line(state.connection, "Disconnected from #{state.connection.host}.")
    update_status(state.connection, "disconnected")
    {:noreply, fail_pending_commands(state, "Connection closed before completion.")}
  end

  def handle_info({:ircxd, {:reconnecting, _payload}}, state) do
    record_server_line(
      state.connection,
      "Reconnecting to #{state.connection.host}:#{state.connection.port}."
    )

    update_status(state.connection, "connecting")

    {:noreply,
     %{
       state
       | registered?: false,
         isupport_received?: false,
         isupport_seen?: false,
         registration_boundary_reached?: false,
         join_validation_ready?: false,
         joins_flushed?: false,
         join_flush_timer: cancel_join_flush_timer(state),
         sent_joins: MapSet.new(),
         joined_channels: MapSet.new()
     }}
  end

  def handle_info(
        {:flush_pending_joins, token},
        %{join_flush_timer: {_timer, token}, registered?: true} = state
      ) do
    info = Ircxd.Client.connection_info(state.client)

    state =
      state
      |> Map.put(:client_info, info)
      |> Map.put(:join_validation_ready?, true)
      |> Map.put(:join_flush_timer, nil)
      |> flush_pending_joins()

    {:noreply, state}
  rescue
    Ecto.NoResultsError -> {:stop, :normal, state}
    Ecto.StaleEntryError -> {:stop, :normal, state}
  catch
    :exit, _reason -> {:noreply, %{state | join_flush_timer: nil}}
  end

  def handle_info({:flush_pending_joins, _token}, state), do: {:noreply, state}

  def handle_info(
        {:ircxd, {:privmsg, %{target: target, nick: nick, body: body} = payload}},
        state
      ) do
    state =
      case action_body(Map.get(payload, :ctcp)) do
        {:ok, action} ->
          {echo_status, state} = pop_pending_echo(state, target, action, "action", payload)

          record_message_for_echo_status(
            echo_status,
            state,
            target,
            nick,
            action,
            "action",
            payload
          )

          state

        :error ->
          {echo_status, state} = pop_pending_echo(state, target, body, "message", payload)

          record_message_for_echo_status(
            echo_status,
            state,
            target,
            nick,
            body,
            "message",
            payload
          )

          state
      end

    {:noreply, state}
  end

  def handle_info({:ircxd, {:notice, %{target: target, nick: nick, body: body} = payload}}, state) do
    {echo_status, state} = pop_pending_echo(state, target, body, "notice", payload)
    record_message_for_echo_status(echo_status, state, target, nick, body, "notice", payload)

    {:noreply, state}
  end

  def handle_info({:ircxd, {:welcome, %{text: text}}}, state) do
    record_server_line(state.connection, text)
    {:noreply, state}
  end

  def handle_info({:ircxd, {:your_host, %{text: text}}}, state) do
    record_server_line(state.connection, text)
    {:noreply, state}
  end

  def handle_info({:ircxd, {:server_created, %{text: text}}}, state) do
    record_server_line(state.connection, text)
    {:noreply, state}
  end

  def handle_info({:ircxd, {:server_info, payload}}, state) do
    record_server_line(
      state.connection,
      "#{payload.server} #{payload.version} user modes #{payload.user_modes} channel modes #{payload.channel_modes}",
      "notice"
    )

    {:noreply, state}
  end

  def handle_info({:ircxd, {:motd_start, %{text: text}}}, state) do
    record_server_line(state.connection, text, "notice")
    {:noreply, state}
  end

  def handle_info({:ircxd, {:motd, %{text: text}}}, state) do
    record_server_line(state.connection, text, "notice")
    {:noreply, state}
  end

  def handle_info({:ircxd, {:motd_end, %{text: text}}}, state) do
    record_server_line(state.connection, text, "notice")
    {:noreply, state}
  end

  def handle_info({:ircxd, {:motd_missing, %{text: text}}}, state) do
    record_server_line(state.connection, text, "notice")
    {:noreply, state}
  end

  def handle_info({:ircxd, {:names, %{channel: channel, names: names}}}, state) do
    normalized = channel_key(state, channel)
    names_buffers = Map.get(state, :names_buffers, %{})
    buffered_names = Map.get(names_buffers, normalized, []) ++ names

    state = Map.put(state, :names_buffers, Map.put(names_buffers, normalized, buffered_names))

    state =
      if MapSet.member?(Map.get(state, :pending_joins, MapSet.new()), normalized) or
           names_include_nick?(names, state.connection.nickname) do
        mark_channel_joined(state, channel)
      else
        state
      end

    {:noreply, state}
  end

  def handle_info({:ircxd, {:names_end, %{channel: channel}}}, state) do
    normalized = channel_key(state, channel)
    names_buffers = Map.get(state, :names_buffers, %{})
    names = Map.get(names_buffers, normalized, [])

    if names != [] do
      Chat.broadcast_presence_sync(state.connection, channel, names, casemapping(state))
    end

    state =
      state
      |> Map.put(:names_buffers, Map.delete(names_buffers, normalized))
      |> maybe_mark_channel_joined_from_names(channel, names)

    {:noreply, state}
  end

  def handle_info({:ircxd, {:join, %{channel: channel, nick: nick} = payload}}, state) do
    self? = source_self?(state, payload, nick)

    if self? do
      {:ok, _membership} =
        Chat.confirm_channel_join(state.connection, channel, casemapping(state), "connected")
    end

    Chat.broadcast_presence_diff(
      state.connection,
      channel,
      %{action: "join", user: %{nick: nick, role: "user", status: "online"}},
      casemapping(state)
    )

    record_channel_line(state, channel, "join", nick, "#{nick} joined #{channel}.")

    state =
      if self? do
        mark_channel_joined(state, channel)
      else
        state
      end

    {:noreply, state}
  end

  def handle_info({:ircxd, {:part, %{channel: channel, nick: nick} = payload}}, state) do
    self? = source_self?(state, payload, nick)

    Chat.broadcast_presence_diff(
      state.connection,
      channel,
      %{action: "part", nick: nick},
      casemapping(state)
    )

    record_channel_line(state, channel, "part", nick, "#{nick} left #{channel}.")

    state =
      if self? do
        {:ok, _membership} =
          Chat.confirm_channel_left(state.connection, channel, casemapping(state))

        %{
          state
          | joined_channels: MapSet.delete(state.joined_channels, channel_key(state, channel))
        }
      else
        state
      end

    {:noreply, state}
  end

  def handle_info({:ircxd, {:quit, %{nick: nick}}}, state) do
    record_channel_line_for_present_nick(state.connection, "quit", nick, fn _membership ->
      "#{nick} quit."
    end)

    Chat.broadcast_presence_diff(state.connection, nil, %{action: "quit", nick: nick})
    {:noreply, state}
  end

  def handle_info(
        {:ircxd, {:nick, %{old_nick: old_nick, new_nick: new_nick} = payload}},
        state
      ) do
    self? = source_self?(state, payload, old_nick)

    record_channel_line_for_present_nick(
      state.connection,
      "nick",
      old_nick,
      new_nick,
      fn _membership -> "#{old_nick} is now #{new_nick}." end
    )

    Chat.broadcast_presence_diff(state.connection, nil, %{
      action: "nick",
      old_nick: old_nick,
      new_nick: new_nick
    })

    unless self? do
      Chat.rename_direct_message_peer(
        state.connection,
        old_nick,
        new_nick,
        sender_metadata(payload),
        casemapping(state)
      )
    end

    state =
      if self? do
        case Chat.update_connection_nickname(state.connection, new_nick, "connected") do
          {:ok, connection} -> %{state | connection: connection}
          {:error, _changeset} -> state
        end
      else
        state
      end

    {:noreply, state}
  end

  def handle_info({:ircxd, {:away, %{nick: nick} = payload}}, state) do
    status = if Map.get(payload, :away?), do: "away", else: "online"

    Chat.broadcast_presence_diff(state.connection, nil, %{
      action: "away",
      nick: nick,
      status: status
    })

    {:noreply, state}
  end

  def handle_info({:ircxd, {:mode, %{target: target} = payload}}, state) do
    if channel_target?(state, target) do
      payload
      |> mode_presence_diffs()
      |> Enum.each(
        &Chat.broadcast_presence_diff(
          state.connection,
          target,
          &1,
          casemapping(state)
        )
      )

      record_channel_line(
        state,
        target,
        "mode",
        Map.get(payload, :nick),
        mode_body(payload)
      )
    else
      record_server_line(state.connection, mode_body(payload), "mode")
    end

    {:noreply, state}
  end

  def handle_info(
        {:ircxd, {:kick, %{channel: channel, nick: nick, target_nick: target_nick} = payload}},
        state
      ) do
    target_self? = self_identity_event?(state, payload, :target_self?, target_nick)

    Chat.broadcast_presence_diff(
      state.connection,
      channel,
      %{action: "part", nick: target_nick},
      casemapping(state)
    )

    record_channel_line(
      state,
      channel,
      "kick",
      nick,
      kick_body(payload)
    )

    state =
      if target_self? do
        case Chat.confirm_channel_left(state.connection, channel, casemapping(state)) do
          {:ok, _membership} ->
            %{
              state
              | joined_channels: MapSet.delete(state.joined_channels, channel_key(state, channel))
            }

          {:error, _reason} ->
            state
        end
      else
        state
      end

    {:noreply, state}
  end

  def handle_info({:ircxd, {:topic, %{channel: channel, nick: nick, topic: topic}}}, state) do
    record_channel_line(
      state,
      channel,
      "topic",
      nick,
      "#{nick} changed the topic to: #{topic}"
    )

    {:noreply, state}
  end

  def handle_info({:ircxd, {:irc_error, payload}}, state) do
    state = reconcile_membership_error(state, payload)
    record_irc_error(state, payload)
    {:noreply, state}
  end

  def handle_info(
        {:ircxd, {:standard_reply, %{type: :fail, command: "JOIN"} = payload}},
        state
      ) do
    pending? = pending_join_command?(state)
    state = reconcile_standard_join_failure(state, payload)

    unless pending? do
      record_server_line(
        state.connection,
        Map.get(payload, :description) || "JOIN failed.",
        "error"
      )
    end

    {:noreply, state}
  end

  def handle_info({:ircxd, {:nick_in_use, payload}}, state) do
    reason = Map.get(payload, :reason) || "That nickname is already in use."
    record_server_line(state.connection, reason, "error")
    {:noreply, state}
  end

  def handle_info({:ircxd, {:list_start, _payload}}, %{channel_list_request: request} = state)
      when not is_nil(request) do
    {:noreply, put_in(state.channel_list_request.entries, %{})}
  end

  def handle_info(
        {:ircxd, {:list_entry, %{channel: channel} = payload}},
        %{channel_list_request: request} = state
      )
      when not is_nil(request) do
    entry = %{
      channel: channel,
      users: parse_visible_users(Map.get(payload, :visible)),
      topic: Map.get(payload, :topic) || ""
    }

    {:noreply, put_in(state.channel_list_request.entries[entry.channel], entry)}
  end

  def handle_info({:ircxd, {:list_end, _payload}}, %{channel_list_request: request} = state)
      when not is_nil(request) do
    Process.cancel_timer(request.timer)

    channels =
      request.entries
      |> Map.values()
      |> Enum.sort_by(fn entry -> {-entry.users, String.downcase(entry.channel)} end)

    GenServer.reply(request.from, {:ok, channels})
    {:noreply, %{state | channel_list_request: nil}}
  end

  def handle_info(
        {:channel_list_timeout, ref},
        %{channel_list_request: %{ref: ref} = request} = state
      ) do
    GenServer.reply(request.from, {:error, :list_timeout})
    {:noreply, %{state | channel_list_request: nil}}
  end

  def handle_info({:channel_list_timeout, _ref}, state), do: {:noreply, state}

  def handle_info({:command_timeout, command_id}, state) do
    case Map.pop(state.pending_commands, command_id) do
      {nil, _pending_commands} ->
        {:noreply, state}

      {pending, pending_commands} ->
        update_command_status(pending, "timed_out", %{error: "No server response was received."})
        {:noreply, %{state | pending_commands: pending_commands}}
    end
  end

  def handle_info({:command_grace_timeout, command_id}, state) do
    case Map.pop(state.pending_commands, command_id) do
      {nil, _pending_commands} ->
        {:noreply, state}

      {pending, pending_commands} ->
        update_command_status(pending, "completed", %{})
        {:noreply, %{state | pending_commands: pending_commands}}
    end
  end

  def handle_info(
        {:ircxd, {:raw, %Message{command: command, params: params}}},
        state
      )
      when byte_size(command) == 3 do
    if String.match?(command, ~r/^\d{3}$/) do
      description = List.last(params) || "No description provided."

      record_server_line(
        state.connection,
        "IRC reply #{command}: #{description}",
        "notice",
        %{irc_event: "raw", numeric: command}
      )
    end

    {:noreply, state}
  end

  def handle_info({:ircxd, event}, state) do
    event_name = legacy_event_name(event)
    now = System.monotonic_time(:second)
    ignored_event_logs = Map.get(state, :ignored_event_logs, %{})

    state =
      if now - Map.get(ignored_event_logs, event_name, now - 61) >= 60 do
        Logger.debug("Ignoring unhandled ircxd event #{event_name}")
        Map.put(state, :ignored_event_logs, Map.put(ignored_event_logs, event_name, now))
      else
        state
      end

    {:noreply, state}
  end

  @impl true
  def handle_call({:join, channel}, _from, state) do
    with :ok <- validate_native_join(state, channel) do
      if MapSet.member?(state.pending_joins, channel_key(state, channel)) do
        {:reply, :ok, state}
      else
        {reply, state} = transmit_join(state, channel)
        reply = if reply in [:sent, :queued], do: :ok, else: reply
        {:reply, reply, state}
      end
    else
      {:error, error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:request_join, user, channel}, _from, state) do
    key = channel_key(state, channel)

    if MapSet.member?(state.pending_joins, key) do
      case Chat.get_channel_membership(state.connection, channel, casemapping(state)) do
        %ChannelMembership{} = membership ->
          status =
            if MapSet.member?(Map.get(state, :sent_joins, MapSet.new()), key),
              do: :sent,
              else: :queued

          {:reply, {:ok, membership, status}, state}

        nil ->
          {:reply, {:error, :already_pending}, state}
      end
    else
      with :ok <- validate_native_join(state, channel),
           {:ok, membership} <-
             Chat.request_channel_join(user, state.connection, channel, casemapping(state)) do
        {reply, state} = transmit_join(state, membership.channel)

        case reply do
          status when status in [:sent, :queued] ->
            {:reply, {:ok, membership, status}, state}

          error ->
            Chat.reject_channel_join(
              state.connection,
              membership.channel,
              error,
              casemapping(state)
            )

            {:reply, error, state}
        end
      else
        {:error, error} -> {:reply, {:error, error}, state}
      end
    end
  end

  def handle_call(:connection_info, _from, %{client: nil} = state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call(:connection_info, _from, state) do
    info = Ircxd.Client.connection_info(state.client)
    {:reply, {:ok, info}, %{state | client_info: info}}
  end

  def handle_call({:execute, intent, command_id, buffer_id}, _from, state) do
    with :ok <- validate_command_id(command_id, state),
         {:ok, client} <- fetch_registered_client(state),
         :ok <- prepare_managed_command(state, intent),
         {:ok, invocation} <- record_command_invocation(state, intent, command_id, buffer_id),
         {message, labeled?} <- maybe_label_command(intent.message, command_id, state) do
      case Ircxd.Client.transmit(client, message) do
        :ok ->
          {state, managed_outcome} = persist_managed_outcome(state, intent)

          state =
            maybe_track_pending_command(
              state,
              intent,
              message,
              invocation,
              command_id,
              buffer_id,
              labeled?
            )

          {:reply,
           {:ok,
            Map.merge(
              %{
                command_id: command_id,
                status: "sent",
                command: String.downcase(message.command),
                display: intent.display
              },
              managed_outcome
            )}, state}

        {:error, reason} ->
          Chat.update_command_message(invocation, %{
            command_status: "failed",
            error: inspect(reason)
          })

          {:reply, {:error, command_execution_error(reason)}, state}
      end
    else
      {:error, %{code: _code} = error} -> {:reply, {:error, error}, state}
      {:error, reason} -> {:reply, {:error, command_execution_error(reason)}, state}
    end
  end

  def handle_call(:list_channels, _from, %{registered?: false} = state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call(:list_channels, _from, %{channel_list_request: request} = state)
      when not is_nil(request) do
    {:reply, {:error, :list_in_progress}, state}
  end

  def handle_call(:list_channels, from, state) do
    with {:ok, client} <- fetch_client(state),
         :ok <- Ircxd.Client.list(client) do
      ref = make_ref()
      timer = Process.send_after(self(), {:channel_list_timeout, ref}, @channel_list_timeout)
      request = %{from: from, ref: ref, timer: timer, entries: %{}}

      {:noreply, %{state | channel_list_request: request}}
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:say, channel, body}, _from, state) do
    with :ok <- CommandRegistry.validate_chat_message(body),
         {:ok, client} <- fetch_joined_client(state, channel),
         :ok <- Ircxd.Client.privmsg(client, channel, body) do
      Chat.record_inbound_message(
        state.connection,
        channel,
        state.connection.nickname,
        body,
        "message",
        %{direction: "outgoing"},
        casemapping(state)
      )

      {:reply, :ok, remember_pending_echo(state, channel, body, "message")}
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:action, channel, body}, _from, state) do
    with {:ok, client} <- fetch_joined_client(state, channel),
         :ok <- Ircxd.Client.privmsg(client, channel, <<1, "ACTION ", body::binary, 1>>) do
      Chat.record_inbound_message(
        state.connection,
        channel,
        state.connection.nickname,
        body,
        "action",
        %{direction: "outgoing"},
        casemapping(state)
      )

      {:reply, :ok, remember_pending_echo(state, channel, body, "action")}
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:privmsg_thread, thread_id, body}, _from, state) do
    with {:ok, client} <- fetch_client(state),
         {:ok, %{thread: thread, message: message}} <-
           Chat.send_direct_message_thread(
             state.connection,
             thread_id,
             body,
             fn peer_nick ->
               with :ok <- CommandRegistry.validate_private_message(peer_nick, body) do
                 Ircxd.Client.privmsg(client, peer_nick, body)
               end
             end
           ) do
      {:reply, {:ok, %{thread: thread, message: message}},
       remember_pending_echo(state, thread.peer_nick, body, "message")}
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:nick, nick}, _from, state) do
    with {:ok, client} <- fetch_client(state),
         :ok <- Ircxd.Client.nick(client, nick) do
      {:reply, :ok, state}
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:topic, channel, topic}, _from, state) do
    with {:ok, client} <- fetch_client(state),
         :ok <- Ircxd.Client.topic(client, channel, topic) do
      {:reply, :ok, state}
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:part, channel, reason}, _from, state) do
    key = channel_key(state, channel)

    if not MapSet.member?(state.joined_channels, key) and MapSet.member?(state.pending_joins, key) and
         not MapSet.member?(Map.get(state, :sent_joins, MapSet.new()), key) do
      case Chat.confirm_channel_left(state.connection, channel, casemapping(state)) do
        {:ok, _membership} ->
          {:reply, :ok, %{state | pending_joins: MapSet.delete(state.pending_joins, key)}}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    else
      with {:ok, client} <- fetch_client(state),
           :ok <- Ircxd.Client.part(client, channel, reason) do
        {:reply, :ok, %{state | pending_joins: MapSet.delete(state.pending_joins, key)}}
      else
        error -> {:reply, error, state}
      end
    end
  end

  def handle_call({:quit, reason}, _from, state) do
    result =
      case state.client do
        nil -> :ok
        client -> Ircxd.Client.quit(client, reason)
      end

    record_server_line(state.connection, "Disconnected from #{state.connection.host}.")
    {:stop, :normal, normalize_result(result), state}
  end

  @impl true
  def terminate(_reason, %{connection: connection} = state) do
    fail_pending_commands(state, "IRC session stopped before completion.")
    update_status(connection, "disconnected")
    :ok
  end

  defp update_status(connection, status) do
    connection =
      if status == "connected" do
        case Chat.touch_connection_connected(connection) do
          {:ok, updated} -> updated
          {:error, _changeset} -> connection
        end
      else
        connection
      end

    Chat.broadcast_server_status(connection, status)
    {:ok, connection}
  rescue
    DBConnection.ConnectionError -> {:ok, connection}
    Ecto.NoResultsError -> {:ok, connection}
    Ecto.StaleEntryError -> {:ok, connection}
    DBConnection.OwnershipError -> {:ok, connection}
  catch
    :exit, _reason -> {:ok, connection}
  end

  defp record_server_line(connection, body, kind \\ "system", metadata \\ %{}) do
    Chat.record_server_message(connection, body, kind, nil, metadata)
  rescue
    DBConnection.ConnectionError -> {:ok, nil}
    Ecto.ConstraintError -> {:ok, nil}
    Ecto.NoResultsError -> {:ok, nil}
    Ecto.StaleEntryError -> {:ok, nil}
    DBConnection.OwnershipError -> {:ok, nil}
  catch
    :exit, _reason -> {:ok, nil}
  end

  defp record_channel_line(state, channel, kind, nick, body) do
    Chat.record_channel_system_message(
      state.connection,
      channel,
      kind,
      nick,
      body,
      %{},
      casemapping(state)
    )
  rescue
    DBConnection.ConnectionError -> {:ok, nil}
    Ecto.ConstraintError -> {:ok, nil}
    Ecto.NoResultsError -> {:ok, nil}
    Ecto.StaleEntryError -> {:ok, nil}
    DBConnection.OwnershipError -> {:ok, nil}
  catch
    :exit, _reason -> {:ok, nil}
  end

  defp record_channel_line_for_present_nick(connection, kind, nick, body_fun) do
    Chat.record_channel_system_message_for_present_nick(connection, kind, nick, body_fun)
  rescue
    DBConnection.ConnectionError -> {:ok, nil}
    Ecto.ConstraintError -> {:ok, nil}
    Ecto.NoResultsError -> {:ok, nil}
    Ecto.StaleEntryError -> {:ok, nil}
    DBConnection.OwnershipError -> {:ok, nil}
  catch
    :exit, _reason -> {:ok, nil}
  end

  defp record_channel_line_for_present_nick(
         connection,
         kind,
         present_nick,
         message_nick,
         body_fun
       ) do
    Chat.record_channel_system_message_for_present_nick(
      connection,
      kind,
      present_nick,
      message_nick,
      body_fun
    )
  rescue
    DBConnection.ConnectionError -> {:ok, nil}
    Ecto.ConstraintError -> {:ok, nil}
    Ecto.NoResultsError -> {:ok, nil}
    Ecto.StaleEntryError -> {:ok, nil}
    DBConnection.OwnershipError -> {:ok, nil}
  catch
    :exit, _reason -> {:ok, nil}
  end

  defp record_irc_error(state, %{target: target} = payload) when is_binary(target) do
    if channel = channel_message_target(state, target) do
      Chat.record_channel_system_message(
        state.connection,
        channel,
        "error",
        nil,
        irc_error_body(payload),
        %{},
        casemapping(state)
      )
    else
      record_server_line(state.connection, irc_error_body(payload), "error")
    end
  rescue
    DBConnection.ConnectionError -> {:ok, nil}
    Ecto.ConstraintError -> {:ok, nil}
    Ecto.NoResultsError -> record_server_line(state.connection, irc_error_body(payload), "error")
    Ecto.StaleEntryError -> {:ok, nil}
    DBConnection.OwnershipError -> {:ok, nil}
  catch
    :exit, _reason -> {:ok, nil}
  end

  defp record_irc_error(state, payload) do
    record_server_line(state.connection, irc_error_body(payload), "error")
  end

  defp reconcile_membership_error(state, %{code: "461", target: target} = payload)
       when is_binary(target) do
    if String.upcase(target) == "JOIN" do
      reject_join_targets(
        state,
        pending_join_targets(state),
        Map.get(payload, :reason) || "461"
      )
    else
      state
    end
  end

  defp reconcile_membership_error(state, %{code: code, target: target} = payload)
       when code in ~w(403 405 471 473 474 475 476 477) and is_binary(target) do
    if pending_join_target?(state, target) do
      reject_join_targets(state, [target], Map.get(payload, :reason) || code)
    else
      state
    end
  end

  defp reconcile_membership_error(state, %{code: "442", target: target} = payload)
       when is_binary(target) do
    if channel_target?(state, target) do
      Chat.reject_channel_part(
        state.connection,
        target,
        Map.get(payload, :reason) || "442",
        casemapping(state)
      )
    end

    state
  end

  defp reconcile_membership_error(state, _payload), do: state

  defp reconcile_standard_join_failure(state, payload) do
    context_targets =
      payload
      |> Map.get(:context)
      |> List.wrap()
      |> Enum.filter(&channel_target?(state, &1))

    targets =
      if context_targets == [] do
        pending_join_targets(state)
      else
        Enum.filter(context_targets, &pending_join_target?(state, &1))
      end

    reject_join_targets(state, targets, Map.get(payload, :description) || "JOIN failed.")
  end

  defp reconcile_command_membership_event(
         state,
         %Event{name: name, payload: %{code: "461", target: target} = payload} = event
       )
       when name in [:irc_error, :error] and is_binary(target) do
    case pending_join_for_event(state, event) do
      {command_id, pending} ->
        if String.upcase(target) == "JOIN" do
          reject_join_targets(
            state,
            pending.targets,
            Map.get(payload, :reason) || "461",
            {command_id, pending}
          )
        else
          state
        end

      nil ->
        if is_nil(event.label) and String.upcase(target) == "JOIN" do
          reject_unambiguous_native_join(state, Map.get(payload, :reason) || "461")
        else
          state
        end
    end
  end

  defp reconcile_command_membership_event(
         state,
         %Event{name: name, payload: %{code: code, target: target} = payload} = event
       )
       when name in [:irc_error, :error] and code in ~w(403 405 471 473 474 475 476 477) and
              is_binary(target) do
    case pending_join_for_event(state, event) do
      {command_id, pending} ->
        if target_matches?(state, target, pending.targets) do
          reject_join_targets(
            state,
            [target],
            Map.get(payload, :reason) || code,
            {command_id, pending}
          )
        else
          state
        end

      nil ->
        if is_nil(event.label) and pending_join_target?(state, target) do
          reject_join_targets(state, [target], Map.get(payload, :reason) || code, :native_only)
        else
          state
        end
    end
  end

  defp reconcile_command_membership_event(
         state,
         %Event{name: name, payload: %{type: :fail, command: "JOIN"} = payload} = event
       )
       when name in [:standard_reply, :standard_reply_error] do
    case pending_join_for_event(state, event) do
      {command_id, pending} ->
        context_targets =
          payload
          |> Map.get(:context)
          |> List.wrap()
          |> Enum.filter(&target_matches?(state, &1, pending.targets))

        all_context_targets =
          payload
          |> Map.get(:context)
          |> List.wrap()
          |> Enum.filter(&channel_target?(state, &1))

        if all_context_targets != [] and context_targets == [] do
          state
        else
          targets = if context_targets == [], do: pending.targets, else: context_targets

          reject_join_targets(
            state,
            targets,
            Map.get(payload, :description) || "JOIN failed.",
            {command_id, pending}
          )
        end

      nil ->
        context_targets =
          payload
          |> Map.get(:context)
          |> List.wrap()
          |> Enum.filter(&pending_join_target?(state, &1))

        cond do
          not is_nil(event.label) ->
            record_unmatched_join_failure(state, payload)

          context_targets != [] ->
            reject_join_targets(
              state,
              context_targets,
              Map.get(payload, :description) || "JOIN failed.",
              :native_only
            )

          true ->
            reject_unambiguous_native_join(
              state,
              Map.get(payload, :description) || "JOIN failed.",
              payload
            )
        end
    end
  end

  defp reconcile_command_membership_event(state, %Event{}), do: state

  defp reject_join_targets(state, targets, reason, correlated_pending \\ :match_unlabeled) do
    targets = Enum.map(targets, &channel_key(state, &1))

    Enum.each(
      targets,
      &Chat.reject_channel_join(state.connection, &1, reason, casemapping(state))
    )

    state =
      state
      |> Map.update(:pending_joins, MapSet.new(), fn pending_joins ->
        Enum.reduce(targets, pending_joins, &MapSet.delete(&2, &1))
      end)
      |> Map.update(:sent_joins, MapSet.new(), fn sent_joins ->
        Enum.reduce(targets, sent_joins, &MapSet.delete(&2, &1))
      end)

    case correlated_pending do
      {command_id, pending} ->
        update_command_status(pending, "failed", %{error: reason})
        finish_pending_command(state, command_id, pending)

      :match_unlabeled ->
        maybe_fail_unlabeled_join(state, targets, reason)

      :native_only ->
        state
    end
  end

  defp reject_unambiguous_native_join(state, reason, unmatched_payload \\ nil) do
    command_targets =
      state.pending_commands
      |> Enum.flat_map(fn
        {_command_id, %{command: "JOIN", targets: targets}} -> targets
        _pending -> []
      end)
      |> MapSet.new()

    native_targets =
      state
      |> Map.get(:sent_joins, MapSet.new())
      |> MapSet.difference(command_targets)
      |> MapSet.to_list()

    case native_targets do
      [target] ->
        reject_join_targets(state, [target], reason, :native_only)

      _targets when is_map(unmatched_payload) ->
        record_unmatched_join_failure(state, unmatched_payload)

      _targets ->
        state
    end
  end

  defp record_unmatched_join_failure(state, payload) do
    record_server_line(
      state.connection,
      Map.get(payload, :description) || Map.get(payload, :reason) || "JOIN failed.",
      "error"
    )

    state
  end

  defp maybe_fail_unlabeled_join(state, rejected_targets, reason) do
    case pending_join_matching_targets(state, rejected_targets, false) do
      {command_id, %{targets: targets} = pending} ->
        if targets != [] and targets -- rejected_targets == [] do
          update_command_status(pending, "failed", %{error: reason})
          finish_pending_command(state, command_id, pending)
        else
          state
        end

      _pending ->
        state
    end
  end

  defp pending_join_for_event(state, %Event{label: label}) when is_binary(label) do
    case Map.get(state.pending_commands, label) do
      %{command: "JOIN"} = pending -> {label, pending}
      _pending -> nil
    end
  end

  defp pending_join_for_event(state, %Event{payload: payload}) do
    targets =
      [Map.get(payload, :target) | List.wrap(Map.get(payload, :context))]
      |> Enum.filter(&channel_target?(state, &1))
      |> Enum.map(&channel_key(state, &1))

    if targets == [],
      do: oldest_pending_join(state, false),
      else: pending_join_matching_targets(state, targets, false)
  end

  defp pending_join_matching_targets(state, targets, labeled?) do
    normalized_targets = Enum.map(targets, &channel_key(state, &1))

    state
    |> Map.get(:pending_commands, %{})
    |> Enum.filter(fn {_command_id, pending} ->
      pending.command == "JOIN" and pending.labeled? == labeled? and
        Enum.any?(normalized_targets, &(&1 in pending.targets))
    end)
    |> Enum.min_by(fn {_command_id, pending} -> pending.invocation.id end, fn -> nil end)
  end

  defp pending_join_targets(state) do
    case oldest_pending_join(state, nil) do
      {_command_id, pending} -> pending.targets
      nil -> []
    end
  end

  defp pending_join_target?(state, target) do
    normalized = channel_key(state, target)

    MapSet.member?(Map.get(state, :pending_joins, MapSet.new()), normalized) or
      Enum.any?(Map.get(state, :pending_commands, %{}), fn
        {_command_id, %{command: "JOIN", targets: targets}} -> normalized in targets
        _other -> false
      end)
  end

  defp pending_join_command?(state), do: not is_nil(oldest_pending_join(state, nil))

  defp oldest_pending_join(state, labeled?) do
    state
    |> Map.get(:pending_commands, %{})
    |> Enum.filter(fn {_command_id, pending} ->
      pending.command == "JOIN" and (is_nil(labeled?) or pending.labeled? == labeled?)
    end)
    |> Enum.min_by(fn {_command_id, pending} -> pending.invocation.id end, fn -> nil end)
  end

  defp irc_error_body(%{reason: reason}) when is_binary(reason), do: reason
  defp irc_error_body(%{code: code}), do: "IRC error #{code}."
  defp irc_error_body(_payload), do: "IRC error."

  defp fetch_client(%{client: nil}), do: {:error, :not_connected}
  defp fetch_client(%{client: client}), do: {:ok, client}

  defp fetch_registered_client(%{registered?: true} = state), do: fetch_client(state)
  defp fetch_registered_client(_state), do: {:error, :not_connected}

  defp membership_failure_event?(%Event{name: name, payload: payload})
       when name in [:irc_error, :error],
       do: Map.get(payload, :code) in ~w(403 405 461 471 473 474 475 476 477)

  defp membership_failure_event?(%Event{name: name, payload: payload})
       when name in [:standard_reply, :standard_reply_error],
       do: Map.get(payload, :type) == :fail and Map.get(payload, :command) == "JOIN"

  defp membership_failure_event?(%Event{}), do: false

  defp maybe_record_membership_failure(%Event{name: name, payload: payload}, state)
       when name in [:irc_error, :error],
       do: record_irc_error(state, payload)

  defp maybe_record_membership_failure(%Event{}, _state), do: :ok

  defp validate_native_join(%{client_info: %Info{} = info, isupport_received?: true}, channel),
    do: CommandRegistry.validate_join_channel(channel, info)

  defp validate_native_join(_state, channel),
    do: CommandRegistry.validate_join_channel_syntax(channel)

  defp transmit_join(state, channel) do
    key = channel_key(state, channel)

    if MapSet.member?(state.joined_channels, key) do
      {:sent, state}
    else
      result =
        case state do
          %{client: client, registered?: true, join_validation_ready?: true}
          when not is_nil(client) ->
            Ircxd.Client.join(client, channel)

          _state ->
            :queued
        end

      case normalize_result(result) do
        :ok ->
          {:sent,
           state
           |> Map.put(:pending_joins, MapSet.put(state.pending_joins, key))
           |> Map.put(:sent_joins, MapSet.put(Map.get(state, :sent_joins, MapSet.new()), key))}

        :queued ->
          {:queued, %{state | pending_joins: MapSet.put(state.pending_joins, key)}}

        error ->
          {error, state}
      end
    end
  end

  defp validate_command_id(command_id, state) when is_binary(command_id) do
    cond do
      not String.match?(command_id, ~r/\A[A-Za-z0-9][A-Za-z0-9._:-]{0,63}\z/) ->
        {:error, :invalid_command_id}

      Map.has_key?(state.pending_commands, command_id) ->
        {:error, :duplicate_command_id}

      true ->
        :ok
    end
  end

  defp validate_command_id(_command_id, _state), do: {:error, :invalid_command_id}

  defp prepare_managed_command(
         state,
         %{disposition: :managed, message: %{command: "JOIN", params: [channels | _rest]}}
       ) do
    channels
    |> String.split(",", trim: true)
    |> Enum.reduce_while(:ok, fn channel, :ok ->
      cond do
        not channel_target?(state, channel) ->
          {:halt, {:error, :invalid_channel}}

        MapSet.member?(state.joined_channels, channel_key(state, channel)) ->
          {:halt, {:error, :already_joined}}

        MapSet.member?(state.pending_joins, channel_key(state, channel)) ->
          {:halt, {:error, :already_pending}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp prepare_managed_command(
         state,
         %{disposition: :managed, message: %{command: command, params: [targets, _body]}}
       )
       when command in ["PRIVMSG", "NOTICE"] do
    targets
    |> String.split(",", trim: true)
    |> Enum.reduce_while(:ok, fn target, :ok ->
      if channel_target?(state, target) and
           not MapSet.member?(state.joined_channels, channel_key(state, target)) do
        {:halt, {:error, :not_joined}}
      else
        {:cont, :ok}
      end
    end)
  end

  defp prepare_managed_command(
         state,
         %{message: %{command: "PART", params: [channels | _rest]}}
       ) do
    validate_joined_targets(state, channels)
  end

  defp prepare_managed_command(
         state,
         %{spec: %{family: :mutation}, message: %{command: command, params: [target | _rest]}}
       )
       when command in ["KICK", "MODE", "TOPIC"] do
    if channel_target?(state, target), do: validate_joined_targets(state, target), else: :ok
  end

  defp prepare_managed_command(_state, _intent), do: :ok

  defp validate_joined_targets(state, targets) do
    targets
    |> String.split(",", trim: true)
    |> Enum.reduce_while(:ok, fn target, :ok ->
      if MapSet.member?(state.joined_channels, channel_key(state, target)),
        do: {:cont, :ok},
        else: {:halt, {:error, :not_joined}}
    end)
  end

  defp record_command_invocation(state, intent, command_id, buffer_id) do
    display = command_invocation_display(state, intent)

    metadata = %{
      command_id: command_id,
      command: intent.message.command,
      command_status: "sent",
      disposition: Atom.to_string(intent.disposition),
      input: display
    }

    case Chat.record_command_message(state.connection, buffer_id, display, metadata) do
      {:ok, invocation} -> {:ok, invocation}
      {:error, reason} -> {:error, reason}
    end
  end

  defp command_invocation_display(
         state,
         %{
           display: display,
           message: %{command: command, params: [targets, _body]}
         }
       )
       when command in ["PRIVMSG", "NOTICE"] do
    if targets
       |> String.split(",", trim: true)
       |> Enum.any?(&(not channel_target?(state, &1))) do
      "#{command} #{targets} :[private message redacted]"
    else
      display
    end
  end

  defp command_invocation_display(_state, intent), do: intent.display

  defp maybe_label_command(message, command_id, %{client_info: %Info{} = info}) do
    if MapSet.member?(info.active_caps, "labeled-response") do
      {%{message | tags: Map.put(message.tags, "label", command_id)}, true}
    else
      {message, false}
    end
  end

  defp maybe_label_command(message, _command_id, _state), do: {message, false}

  defp persist_managed_outcome(
         state,
         %{disposition: :managed, message: %{command: "JOIN", params: [channels | _rest]}}
       ) do
    user = Repo.get!(User, state.connection.user_id)

    next_state =
      channels
      |> String.split(",", trim: true)
      |> Enum.reduce(state, fn channel, current_state ->
        {:ok, membership} =
          Chat.request_channel_join(user, state.connection, channel, casemapping(current_state))

        key = channel_key(current_state, membership.channel)

        current_state
        |> Map.update!(:pending_joins, &MapSet.put(&1, key))
        |> Map.update!(:sent_joins, &MapSet.put(&1, key))
      end)

    {next_state, %{}}
  end

  defp persist_managed_outcome(
         state,
         %{disposition: :managed, message: %{command: command, params: [targets, body]}}
       )
       when command in ["PRIVMSG", "NOTICE"] do
    {kind, body} = outgoing_kind_and_body(command, body)

    {next_state, direct_messages} =
      Enum.reduce(
        String.split(targets, ",", trim: true),
        {state, []},
        fn target, {current_state, direct_messages} ->
          metadata = %{direction: "outgoing", peer_nick: target, target: target}

          direct_messages =
            if channel = channel_message_target(current_state, target) do
              Chat.record_inbound_message(
                current_state.connection,
                channel,
                current_state.connection.nickname,
                body,
                kind,
                metadata,
                casemapping(current_state)
              )

              direct_messages
            else
              case Chat.record_direct_message(
                     current_state.connection,
                     target,
                     current_state.connection.nickname,
                     body,
                     kind,
                     metadata,
                     casemapping(current_state)
                   ) do
                {:ok, %{thread: thread, message: message}} ->
                  [%{thread: thread, message: message} | direct_messages]

                _error ->
                  direct_messages
              end
            end

          {remember_pending_echo(current_state, target, body, kind), direct_messages}
        end
      )

    {next_state, %{direct_messages: Enum.reverse(direct_messages)}}
  end

  defp persist_managed_outcome(state, _intent), do: {state, %{}}

  defp outgoing_kind_and_body("PRIVMSG", <<1, "ACTION ", rest::binary>>) do
    {"action", String.trim_trailing(rest, <<1>>)}
  end

  defp outgoing_kind_and_body("PRIVMSG", body), do: {"message", body}
  defp outgoing_kind_and_body("NOTICE", body), do: {"notice", body}

  defp maybe_track_pending_command(
         state,
         intent,
         message,
         invocation,
         command_id,
         buffer_id,
         labeled?
       ) do
    terminal_events = effective_terminal_events(message.command, intent.spec)

    if labeled? or intent.spec.result_events != [] or terminal_events != [] do
      pending = %{
        command_id: command_id,
        buffer_id: buffer_id,
        command: message.command,
        targets: correlation_targets(state, message),
        spec: Map.put(intent.spec, :terminal_events, terminal_events),
        invocation: invocation,
        labeled?: labeled?,
        timer: Process.send_after(self(), {:command_timeout, command_id}, @command_timeout)
      }

      %{state | pending_commands: Map.put(state.pending_commands, command_id, pending)}
    else
      state
    end
  end

  defp correlation_targets(state, %Message{command: command, params: [targets | _rest]})
       when command in ["JOIN", "PART", "PRIVMSG", "NOTICE"] do
    targets
    |> String.split(",", trim: true)
    |> Enum.map(&normalize_correlation_target(state, &1))
  end

  defp correlation_targets(state, %Message{command: command, params: [target | _rest]})
       when command in ["NICK", "TOPIC", "MODE", "KICK", "INVITE"] do
    [normalize_correlation_target(state, target)]
  end

  defp correlation_targets(state, %Message{command: command, params: params})
       when command in ["ISON", "USERHOST"] do
    Enum.map(params, &normalize_correlation_target(state, &1))
  end

  defp correlation_targets(state, %Message{command: "WHOIS", params: params}) do
    case List.last(params) do
      target when is_binary(target) -> [normalize_correlation_target(state, target)]
      _target -> []
    end
  end

  defp correlation_targets(state, %Message{command: command, params: [targets | _rest]})
       when command in ["LIST", "NAMES", "WHO", "WHOWAS"] do
    targets
    |> String.split(",", trim: true)
    |> Enum.map(&normalize_correlation_target(state, &1))
  end

  defp correlation_targets(_state, %Message{}), do: []

  defp normalize_correlation_target(state, target) do
    if channel_target?(state, target),
      do: channel_key(state, target),
      else: normalize_identifier(state, target)
  end

  defp effective_terminal_events(command, spec) do
    application_events =
      case {command, spec.family} do
        {"AWAY", _family} -> [:away, :now_away, :unaway]
        {"INVITE", _family} -> [:inviting, :invite]
        {"JOIN", _family} -> [:join]
        {"KICK", _family} -> [:kick]
        {"MODE", :mutation} -> [:mode]
        {"NICK", _family} -> [:nick]
        {"PART", _family} -> [:part]
        {"QUIT", _family} -> [:disconnect, :disconnected]
        {"TOPIC", :mutation} -> [:topic]
        {_command, _family} -> []
      end

    Enum.uniq(spec.terminal_events ++ application_events)
  end

  defp process_command_event(state, %Event{name: :labeled_request, payload: payload}) do
    command_id = Map.get(payload, :label)

    case Map.get(state.pending_commands, command_id) do
      nil ->
        state

      pending ->
        status = payload |> Map.get(:status) |> lifecycle_status()
        update_command_status(pending, status, lifecycle_metadata(payload))

        if status in ["completed", "failed"] do
          finish_pending_command(state, command_id, pending)
        else
          state
        end
    end
  end

  defp process_command_event(state, %Event{derivative?: true}), do: state

  defp process_command_event(state, %Event{} = event) do
    case pending_for_event(state, event) do
      {command_id, pending} ->
        state = maybe_record_command_result(state, event, pending)

        cond do
          not pending.labeled? and pending.command != "JOIN" and
            event.name in [:standard_reply, :standard_reply_error] and
              Map.get(event.payload, :type) == :fail ->
            update_command_status(pending, "failed", %{
              error: Map.get(event.payload, :description) || "Command failed."
            })

            finish_pending_command(state, command_id, pending)

          not pending.labeled? and event.name in pending.spec.terminal_events ->
            update_command_status(pending, "completed", %{})
            finish_pending_command(state, command_id, pending)

          not pending.labeled? and pending.spec.terminal_events == [] and
              event.name in pending.spec.result_events ->
            reschedule_pending_grace(state, command_id, pending)

          true ->
            state
        end

      nil ->
        state
    end
  end

  defp suppress_correlated_legacy_output?(state, %Event{name: name})
       when name in [:motd_start, :motd] do
    state
    |> Map.get(:pending_commands, %{})
    |> Enum.any?(fn {_command_id, pending} -> pending.command == "MOTD" end)
  end

  defp suppress_correlated_legacy_output?(_state, %Event{}), do: false

  defp pending_for_event(state, %Event{label: label}) when is_binary(label) do
    case Map.get(state.pending_commands, label) do
      nil -> nil
      pending -> {label, pending}
    end
  end

  defp pending_for_event(state, %Event{} = event) do
    state.pending_commands
    |> Enum.filter(fn {_command_id, pending} ->
      not pending.labeled? and
        event_matches_pending?(state, event, pending)
    end)
    |> Enum.min_by(fn {_command_id, pending} -> pending.invocation.id end, fn -> nil end)
  end

  defp event_matches_pending?(
         state,
         %Event{name: :join, payload: payload},
         %{command: "JOIN"} = pending
       ) do
    channel = Map.get(payload, :channel)
    nick = Map.get(payload, :nick)

    self_event?(state, payload, nick) and target_matches?(state, channel, pending.targets)
  end

  defp event_matches_pending?(
         state,
         %Event{name: :part, payload: payload},
         %{command: "PART"} = pending
       ) do
    channel = Map.get(payload, :channel)
    nick = Map.get(payload, :nick)

    self_event?(state, payload, nick) and target_matches?(state, channel, pending.targets)
  end

  defp event_matches_pending?(
         state,
         %Event{name: :nick, payload: payload},
         %{command: "NICK"} = pending
       ) do
    new_nick = Map.get(payload, :new_nick)
    old_nick = Map.get(payload, :old_nick)

    self_event?(state, payload, old_nick) and target_matches?(state, new_nick, pending.targets)
  end

  defp event_matches_pending?(
         state,
         %Event{name: :topic, payload: payload},
         %{command: "TOPIC"} = pending
       ) do
    channel = Map.get(payload, :channel)
    nick = Map.get(payload, :nick)

    pending.spec.family == :mutation and self_event?(state, payload, nick) and
      target_matches?(state, channel, pending.targets)
  end

  defp event_matches_pending?(state, %Event{name: name, payload: payload}, pending)
       when name in [:standard_reply, :standard_reply_error] do
    Map.get(payload, :command) == pending.command and
      standard_reply_target_matches?(state, payload, pending.targets)
  end

  defp event_matches_pending?(state, %Event{name: name} = event, pending) do
    name in (pending.spec.result_events ++ pending.spec.terminal_events) and
      query_target_matches?(state, event, pending.targets)
  end

  defp query_target_matches?(_state, _event, []), do: true

  defp query_target_matches?(state, %Event{payload: payload}, targets) when is_map(payload) do
    candidates =
      [:channel, :target, :nick, :mask]
      |> Enum.map(&Map.get(payload, &1))
      |> Enum.filter(&is_binary/1)

    candidates == [] or Enum.any?(candidates, &target_matches?(state, &1, targets))
  end

  defp query_target_matches?(_state, _event, _targets), do: true

  defp standard_reply_target_matches?(_state, _payload, []), do: true

  defp standard_reply_target_matches?(state, payload, targets) do
    case Map.get(payload, :context, []) do
      [] ->
        true

      context ->
        Enum.any?(context, fn
          value when is_binary(value) -> normalize_correlation_target(state, value) in targets
          _value -> false
        end)
    end
  end

  defp self_event?(state, payload, nick) do
    self_identity_event?(state, payload, :source_self?, nick)
  end

  defp target_matches?(state, target, targets) when is_binary(target),
    do: normalize_correlation_target(state, target) in targets

  defp target_matches?(_state, _target, _targets), do: false

  defp maybe_record_command_result(state, event, pending) do
    if command_result_event?(event, pending) do
      formatted = CommandResult.format(event)

      metadata =
        Map.merge(formatted.metadata, %{
          command_id: pending.command_id,
          command: pending.command,
          command_status: "result"
        })

      _result =
        Chat.record_command_message(
          state.connection,
          result_buffer_id(state, event, pending),
          formatted.body,
          metadata
        )
    end

    state
  end

  defp command_result_event?(%Event{name: name}, pending) do
    name in pending.spec.result_events or name in [:standard_reply, :standard_reply_error]
  end

  defp result_buffer_id(state, event, pending) do
    channel =
      if is_map(event.payload) do
        Map.get(event.payload, :channel) || Map.get(event.payload, :target)
      end

    if is_binary(channel) and channel_target?(state, channel) do
      case Chat.get_channel_membership(state.connection, channel, casemapping(state)) do
        %ChannelMembership{id: membership_id, status: status}
        when status in ["pending", "joined"] ->
          "channel:#{membership_id}"

        _membership ->
          pending.buffer_id
      end
    else
      pending.buffer_id
    end
  end

  defp finish_pending_command(state, command_id, pending) do
    Process.cancel_timer(pending.timer)
    %{state | pending_commands: Map.delete(state.pending_commands, command_id)}
  end

  defp reschedule_pending_grace(state, command_id, pending) do
    Process.cancel_timer(pending.timer)

    pending = %{
      pending
      | timer:
          Process.send_after(
            self(),
            {:command_grace_timeout, command_id},
            @command_grace_timeout
          )
    }

    %{state | pending_commands: Map.put(state.pending_commands, command_id, pending)}
  end

  defp fail_pending_commands(state, reason) do
    Enum.each(Map.get(state, :pending_commands, %{}), fn {_command_id, pending} ->
      Process.cancel_timer(pending.timer)
      update_command_status(pending, "failed", %{error: reason})
    end)

    Map.put(state, :pending_commands, %{})
  end

  defp update_command_status(pending, status, metadata) do
    Chat.update_command_message(
      pending.invocation,
      Map.merge(metadata, %{command_status: status})
    )
  rescue
    DBConnection.ConnectionError -> {:ok, nil}
    Ecto.NoResultsError -> {:ok, nil}
    Ecto.StaleEntryError -> {:ok, nil}
    DBConnection.OwnershipError -> {:ok, nil}
  catch
    :exit, _reason -> {:ok, nil}
  end

  defp lifecycle_status(:sent), do: "sent"
  defp lifecycle_status(:acknowledged), do: "acknowledged"
  defp lifecycle_status(:completed), do: "completed"
  defp lifecycle_status(:failed), do: "failed"
  defp lifecycle_status(_status), do: "sent"

  defp lifecycle_metadata(payload) do
    case Map.get(payload, :reason) do
      nil -> %{}
      reason -> %{error: inspect(reason)}
    end
  end

  defp command_execution_error(reason) do
    %{
      code: error_code(reason),
      message: command_execution_message(reason),
      recoverable: reason not in [:invalid_command_id, :duplicate_command_id]
    }
  end

  defp error_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_code(_reason), do: "command_failed"

  defp command_execution_message(:not_connected),
    do: "Connect to the server before running a command."

  defp command_execution_message(:invalid_command_id), do: "The command identifier is invalid."
  defp command_execution_message(:duplicate_command_id), do: "This command was already submitted."
  defp command_execution_message(:already_joined), do: "You are already in that channel."
  defp command_execution_message(:not_joined), do: "Join that channel before sending to it."

  defp command_execution_message(reason),
    do: "The IRC command could not be sent: #{inspect(reason)}"

  defp parse_visible_users(value) when is_integer(value), do: value

  defp parse_visible_users(value) when is_binary(value) do
    case Integer.parse(value) do
      {count, ""} -> count
      _other -> 0
    end
  end

  defp parse_visible_users(_value), do: 0

  defp fetch_joined_client(state, channel) do
    normalized = channel_key(state, channel)

    cond do
      state.client == nil ->
        {:error, :not_connected}

      MapSet.member?(state.joined_channels, normalized) ->
        {:ok, state.client}

      MapSet.member?(state.pending_joins, normalized) ->
        {:error, :joining_channel}

      true ->
        {:error, :not_joined}
    end
  end

  defp mark_channel_joined(state, channel) do
    normalized = channel_key(state, channel)

    state
    |> Map.put(
      :pending_joins,
      MapSet.delete(Map.get(state, :pending_joins, MapSet.new()), normalized)
    )
    |> Map.put(
      :joined_channels,
      MapSet.put(Map.get(state, :joined_channels, MapSet.new()), normalized)
    )
    |> Map.put(:sent_joins, MapSet.delete(Map.get(state, :sent_joins, MapSet.new()), normalized))
  end

  defp maybe_mark_channel_joined_from_names(state, channel, names) do
    normalized = channel_key(state, channel)

    if MapSet.member?(Map.get(state, :pending_joins, MapSet.new()), normalized) or
         names_include_nick?(names, state.connection.nickname) do
      mark_channel_joined(state, channel)
    else
      state
    end
  end

  defp names_include_nick?(names, nick) when is_list(names) do
    Enum.any?(names, fn
      %{nick: listed_nick} -> same_nick?(listed_nick, nick)
      %{"nick" => listed_nick} -> same_nick?(listed_nick, nick)
      listed_nick when is_binary(listed_nick) -> same_nick?(listed_nick, nick)
      _other -> false
    end)
  end

  defp names_include_nick?(_names, _nick), do: false

  defp source_self?(state, payload, nick) do
    self_identity_event?(state, payload, :source_self?, nick)
  end

  defp self_identity_event?(%{isupport_received?: true} = state, payload, key, nick) do
    Map.get(payload, key, identifier_self?(state, nick))
  end

  defp self_identity_event?(state, _payload, _key, nick), do: identifier_self?(state, nick)

  defp identifier_self?(%{client_info: %Info{} = info, isupport_received?: true} = state, nick) do
    is_binary(info.current_nick) and is_binary(nick) and
      Ircxd.Casemapping.normalize(info.current_nick, casemapping(state)) ==
        Ircxd.Casemapping.normalize(nick, casemapping(state))
  end

  defp identifier_self?(%{connection: connection}, nick) do
    is_binary(nick) and
      Ircxd.Casemapping.normalize(nick, stored_connection_casemapping(connection)) ==
        Ircxd.Casemapping.normalize(
          connection.nickname,
          stored_connection_casemapping(connection)
        )
  end

  defp identifier_self?(_state, _nick), do: false

  defp same_nick?(left, right) when is_binary(left) and is_binary(right) do
    String.downcase(left) == String.downcase(right)
  end

  defp same_nick?(_left, _right), do: false

  defp stored_connection_casemapping(%ServerConnection{casemapping: "rfc1459"}), do: :rfc1459

  defp stored_connection_casemapping(%ServerConnection{casemapping: "strict_rfc1459"}),
    do: :strict_rfc1459

  defp stored_connection_casemapping(_connection), do: :ascii

  defp remember_pending_echo(state, target, body, kind) do
    pending_echoes =
      PendingEchoes.remember(
        state.pending_echoes,
        normalize_identifier(state, target),
        body,
        kind
      )

    %{state | pending_echoes: pending_echoes}
  end

  defp pop_pending_echo(state, channel, body, kind, %{nick: nick} = payload) do
    if source_self?(state, payload, nick) do
      case PendingEchoes.pop(
             state.pending_echoes,
             normalize_identifier(state, channel),
             body,
             kind
           ) do
        {:unmatched, pending_echoes} ->
          {:unmatched_self, %{state | pending_echoes: pending_echoes}}

        {:matched, pending_echoes} ->
          {:matched, %{state | pending_echoes: pending_echoes}}
      end
    else
      {:incoming, state}
    end
  end

  defp pop_pending_echo(state, _channel, _body, _kind, _payload), do: {:incoming, state}

  defp record_message_for_echo_status(:matched, _state, _target, _nick, _body, _kind, _payload),
    do: :ok

  defp record_message_for_echo_status(
         :unmatched_self,
         state,
         target,
         nick,
         body,
         kind,
         payload
       ) do
    record_outgoing_echo(state, target, nick, body, kind, payload)
  end

  defp record_message_for_echo_status(:incoming, state, target, nick, body, kind, payload) do
    record_received_message(state, target, nick, body, kind, payload)
  end

  defp record_outgoing_echo(state, target, nick, body, kind, payload) do
    metadata =
      payload
      |> sender_metadata()
      |> Map.merge(%{direction: "outgoing", peer_nick: target, target: target})

    if channel = channel_message_target(state, target) do
      Chat.record_inbound_message(
        state.connection,
        channel,
        nick,
        body,
        kind,
        metadata,
        casemapping(state)
      )
    else
      record_direct_received_line(
        state.connection,
        target,
        nick,
        body,
        kind,
        metadata,
        casemapping(state)
      )
    end
  end

  defp record_received_message(state, target, nick, body, kind, payload) do
    metadata =
      payload
      |> sender_metadata()
      |> Map.merge(%{direction: "incoming", peer_nick: nick, target: target})

    if channel = channel_message_target(state, target) do
      Chat.record_inbound_message(
        state.connection,
        channel,
        nick,
        body,
        kind,
        metadata,
        casemapping(state)
      )
    else
      if user_message_source?(payload) do
        record_direct_received_line(
          state.connection,
          nick,
          nick,
          body,
          kind,
          Map.put(metadata, :service, service_name(nick)),
          casemapping(state)
        )
      else
        record_server_received_line(
          state.connection,
          body,
          kind,
          nick,
          Map.put(metadata, :service, service_name(nick))
        )
      end
    end
  end

  defp user_message_source?(payload) do
    source = Map.get(payload, :source)
    raw_source = Map.get(payload, :raw_source)

    (is_map(source) and Map.get(source, :type) == :user) or
      (is_binary(raw_source) and String.contains?(raw_source, "!"))
  end

  defp record_server_received_line(connection, body, kind, nick, metadata) do
    Chat.record_server_message(connection, body, kind, nick, metadata)
  rescue
    DBConnection.ConnectionError -> {:ok, nil}
    Ecto.ConstraintError -> {:ok, nil}
    Ecto.NoResultsError -> {:ok, nil}
    Ecto.StaleEntryError -> {:ok, nil}
    DBConnection.OwnershipError -> {:ok, nil}
  catch
    :exit, _reason -> {:ok, nil}
  end

  defp record_direct_received_line(connection, peer_nick, nick, body, kind, metadata, casemapping) do
    Chat.record_direct_message(connection, peer_nick, nick, body, kind, metadata, casemapping)
  rescue
    DBConnection.ConnectionError -> {:ok, nil}
    Ecto.ConstraintError -> {:ok, nil}
    Ecto.NoResultsError -> {:ok, nil}
    Ecto.StaleEntryError -> {:ok, nil}
    DBConnection.OwnershipError -> {:ok, nil}
  catch
    :exit, _reason -> {:ok, nil}
  end

  defp channel_message_target(
         %{client_info: %Info{isupport: isupport}, isupport_received?: true},
         target
       )
       when is_binary(target) do
    cond do
      ISupport.status_target?(isupport, target) -> String.slice(target, 1..-1//1)
      ISupport.channel?(isupport, target) -> target
      true -> nil
    end
  end

  defp channel_message_target(_state, <<prefix, _rest::binary>> = target)
       when prefix in [?#, ?&, ?+, ?!],
       do: target

  defp channel_message_target(_state, _target), do: nil

  defp channel_target?(state, target), do: not is_nil(channel_message_target(state, target))

  defp normalize_identifier(
         %{client_info: %Info{casemapping: mapping}, isupport_received?: true},
         identifier
       ),
       do: Ircxd.Casemapping.normalize(identifier, mapping)

  defp normalize_identifier(state, identifier),
    do: Ircxd.Casemapping.normalize(identifier, casemapping(state))

  defp casemapping(%{active_casemapping: mapping}) when not is_nil(mapping), do: mapping

  defp casemapping(%{connection: %ServerConnection{casemapping: "ascii"}}), do: :ascii

  defp casemapping(%{connection: %ServerConnection{casemapping: "strict_rfc1459"}}),
    do: :strict_rfc1459

  defp casemapping(%{connection: %ServerConnection{casemapping: "rfc1459"}}), do: :rfc1459
  defp casemapping(_state), do: :ascii

  defp channel_key(state, channel) do
    Identifier.key(channel_message_target(state, channel) || channel, casemapping(state))
  end

  defp normalize_result(:ok), do: :ok
  defp normalize_result(error), do: error

  defp maybe_refresh_client_info(state, event_name)
       when event_name in [:isupport, :isupport_batch] do
    state =
      state
      |> refresh_client_info()
      |> Map.put(:isupport_seen?, true)

    if Map.get(state, :registration_boundary_reached?, false) do
      finalize_registration_support(state)
    else
      state
    end
  end

  defp maybe_refresh_client_info(state, event_name)
       when event_name in [:motd_end, :motd_missing] do
    state
    |> refresh_client_info()
    |> Map.put(:registration_boundary_reached?, true)
    |> finalize_registration_support()
  end

  defp maybe_refresh_client_info(state, event_name)
       when event_name in [
              :registered,
              :welcome,
              :cap_ack,
              :cap_del,
              :cap_nak,
              :cap_new,
              :nick,
              :connected,
              :disconnected,
              :disconnect,
              :reconnecting
            ],
       do: refresh_client_info(state)

  defp maybe_refresh_client_info(state, _event_name), do: state

  defp refresh_client_info(%{client: nil} = state), do: Map.put(state, :client_info, nil)

  defp refresh_client_info(%{client: client} = state) do
    info = Ircxd.Client.connection_info(client)
    connection = state.connection
    mapping = casemapping(state)
    joined_channels = rekey_channels(state.joined_channels, mapping)

    pending_joins =
      connection
      |> persisted_channels(mapping)
      |> MapSet.difference(joined_channels)

    state
    |> Map.put(:connection, connection)
    |> Map.put(:client_info, info)
    |> Map.put(:pending_joins, pending_joins)
    |> Map.put(:joined_channels, joined_channels)
  catch
    :exit, _reason -> Map.put(state, :client_info, nil)
  end

  defp schedule_join_flush(%{registered?: true, join_validation_ready?: false} = state) do
    _ = cancel_join_flush_timer(state)
    token = make_ref()
    timer = Process.send_after(self(), {:flush_pending_joins, token}, @isupport_settle_timeout)
    %{state | join_flush_timer: {timer, token}}
  end

  defp schedule_join_flush(state), do: state

  defp cancel_join_flush_timer(state) do
    case Map.get(state, :join_flush_timer) do
      {timer, _token} -> Process.cancel_timer(timer)
      _timer -> :ok
    end

    nil
  end

  defp persist_casemapping(connection, casemapping) do
    mapping = Atom.to_string(casemapping)

    if connection.casemapping == mapping do
      connection
    else
      {:ok, updated} = Chat.update_connection_casemapping(connection, casemapping)
      {:ok, _losers} = Chat.reconcile_channel_memberships(updated, casemapping)
      updated
    end
  end

  defp finalize_registration_support(%{isupport_seen?: true, client_info: %Info{} = info} = state) do
    connection = persist_casemapping(state.connection, info.casemapping)
    mapping = info.casemapping

    state
    |> Map.put(:connection, connection)
    |> Map.put(:active_casemapping, mapping)
    |> rekey_runtime_channels(mapping)
    |> Map.put(:isupport_received?, true)
    |> Map.put(:join_validation_ready?, true)
    |> Map.put(:join_flush_timer, cancel_join_flush_timer(state))
    |> flush_pending_joins()
  end

  defp finalize_registration_support(state) do
    state
    |> Map.put(:join_validation_ready?, true)
    |> Map.put(:join_flush_timer, cancel_join_flush_timer(state))
    |> flush_pending_joins()
  end

  defp rekey_runtime_channels(state, mapping) do
    state
    |> Map.update(:pending_joins, MapSet.new(), &rekey_channels(&1, mapping))
    |> Map.update(:joined_channels, MapSet.new(), &rekey_channels(&1, mapping))
    |> Map.update(:sent_joins, MapSet.new(), &rekey_channels(&1, mapping))
  end

  defp flush_pending_joins(state) do
    ChannelMembership
    |> where(
      [membership],
      membership.server_connection_id == ^state.connection.id and membership.auto_join and
        membership.status in ["pending", "joined"]
    )
    |> Repo.all()
    |> Enum.reduce(state, fn membership, current_state ->
      channel = membership.channel
      key = channel_key(current_state, channel)

      if MapSet.member?(current_state.joined_channels, key) or
           MapSet.member?(Map.get(current_state, :sent_joins, MapSet.new()), key) do
        current_state
      else
        with :ok <- validate_native_join(current_state, channel),
             :ok <- Ircxd.Client.join(current_state.client, channel) do
          current_state
          |> Map.put(:pending_joins, MapSet.put(current_state.pending_joins, key))
          |> Map.put(
            :sent_joins,
            MapSet.put(Map.get(current_state, :sent_joins, MapSet.new()), key)
          )
        else
          {:error, reason} ->
            if current_state.isupport_received? do
              Chat.reject_channel_join(
                current_state.connection,
                channel,
                reason,
                casemapping(current_state)
              )

              %{current_state | pending_joins: MapSet.delete(current_state.pending_joins, key)}
            else
              current_state
            end
        end
      end
    end)
    |> Map.put(:joins_flushed?, true)
  end

  defp rekey_channels(channels, casemapping) do
    channels
    |> Enum.map(&Identifier.key(&1, casemapping))
    |> MapSet.new()
  end

  defp action_body({:ok, %{command: "ACTION", params: params}}), do: {:ok, params}
  defp action_body(_ctcp), do: :error

  defp sender_metadata(payload) do
    %{
      account: Map.get(payload, :account),
      hostmask: Map.get(payload, :raw_source),
      sender_role: role_from_prefixes(Map.get(payload, :prefixes, []))
    }
  end

  defp role_from_prefixes(prefixes) when is_list(prefixes) do
    cond do
      "~" in prefixes -> "owner"
      "&" in prefixes -> "admin"
      "@" in prefixes -> "op"
      "%" in prefixes -> "halfop"
      "+" in prefixes -> "voice"
      true -> nil
    end
  end

  defp role_from_prefixes(_prefixes), do: nil

  defp mode_presence_diffs(%{modes: modes, params: params}) do
    modes
    |> String.graphemes()
    |> Enum.reduce({"+", params, []}, fn
      sign, {_current_sign, remaining_params, diffs} when sign in ["+", "-"] ->
        {sign, remaining_params, diffs}

      mode, {sign, remaining_params, diffs} ->
        {nick, next_params} =
          if mode_argument?(mode, sign) do
            {List.first(remaining_params), Enum.drop(remaining_params, 1)}
          else
            {nil, remaining_params}
          end

        diff =
          if mode in ["q", "a", "o", "h", "v"] && is_binary(nick) do
            %{
              action: "role",
              nick: nick,
              role: if(sign == "+", do: role_for_mode(mode), else: "user")
            }
          end

        {sign, next_params, maybe_append(diffs, diff)}
    end)
    |> elem(2)
    |> Enum.reverse()
  end

  defp mode_presence_diffs(_payload), do: []

  defp mode_argument?(mode, _sign) when mode in ["q", "a", "o", "h", "v", "b", "e", "I", "k"],
    do: true

  defp mode_argument?("l", "+"), do: true
  defp mode_argument?(_mode, _sign), do: false

  defp role_for_mode("q"), do: "owner"
  defp role_for_mode("a"), do: "admin"
  defp role_for_mode("o"), do: "op"
  defp role_for_mode("h"), do: "halfop"
  defp role_for_mode("v"), do: "voice"

  defp maybe_append(list, nil), do: list
  defp maybe_append(list, item), do: [item | list]

  defp service_name(nick) when is_binary(nick) do
    if String.ends_with?(nick, "Serv"), do: nick
  end

  defp service_name(_nick), do: nil

  defp mode_body(payload) do
    setter = if present?(Map.get(payload, :nick)), do: Map.get(payload, :nick), else: "server"
    modes = Map.get(payload, :modes)
    rendered_params = Enum.join(Map.get(payload, :params, []), " ")

    mode_text =
      if present?(rendered_params) do
        "#{modes} #{rendered_params}"
      else
        modes
      end

    "#{setter} set mode #{mode_text}."
  end

  defp kick_body(%{nick: nick, target_nick: target_nick, reason: reason}) do
    kicker = if present?(nick), do: nick, else: "server"

    if present?(reason) do
      "#{target_nick} was kicked by #{kicker}: #{reason}"
    else
      "#{target_nick} was kicked by #{kicker}."
    end
  end

  defp persisted_channels(connection, casemapping \\ :rfc1459)

  defp persisted_channels(%ServerConnection{} = connection, casemapping) do
    ChannelMembership
    |> where(
      [membership],
      membership.server_connection_id == ^connection.id and membership.auto_join and
        membership.status in ["pending", "joined"]
    )
    |> Repo.all()
    |> Enum.map(&Identifier.key(&1.channel, casemapping))
    |> MapSet.new()
  end

  defp present?(value), do: is_binary(value) and value != ""

  defp legacy_event_name(name) when is_atom(name), do: Atom.to_string(name)
  defp legacy_event_name(event) when is_tuple(event), do: event |> elem(0) |> to_string()
  defp legacy_event_name(_event), do: "unknown"
end
