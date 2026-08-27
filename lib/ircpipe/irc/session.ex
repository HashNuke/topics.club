defmodule Ircpipe.Irc.Session do
  use GenServer

  import Ecto.Query

  require Logger

  alias Ircpipe.Chat
  alias Ircpipe.Chat.Presence
  alias Ircpipe.Chat.ConnectionLifecycle
  alias Ircpipe.Chat.DirectMessageIngestion
  alias Ircpipe.Chat.DirectMessageSender
  alias Ircpipe.Chat.DirectMessageRenamer
  alias Ircpipe.Chat.MembershipReconciler
  alias Ircpipe.Irc.CommandRegistry
  alias Ircpipe.Irc.ConnectionLock
  alias Ircpipe.Irc.EventFormatting
  alias Ircpipe.Irc.Session.CommandLifecycle
  alias Ircpipe.Irc.Session.Identity
  alias Ircpipe.Irc.Session.InboundMessageRouting
  alias Ircpipe.Irc.Session.JoinLifecycle
  alias Ircpipe.Irc.Session.JoinReconciliation
  alias Ircpipe.Irc.Session.PendingEchoes
  alias Ircpipe.Irc.Session.Targets
  alias Ircpipe.Repo
  alias Ircpipe.Chat.{ChannelMembership, ServerConnection}
  alias Ircpipe.Accounts.User
  alias Ircxd.Message
  alias Ircxd.Client.{Event, Info}

  @channel_list_timeout 10_000

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
    case whereis(connection) do
      nil ->
        "disconnected"

      _pid ->
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

  def whereis(%ServerConnection{} = connection), do: GenServer.whereis(via(connection))

  @impl true
  def init(%ServerConnection{} = requested_connection) do
    case start_payload(requested_connection) do
      {%ServerConnection{} = connection, pending_channels} ->
        send(self(), :connect)

        {:ok,
         %{
           connection: connection,
           client: nil,
           registered?: false,
           pending_joins: pending_channels,
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

      nil ->
        :ignore

      {:error, reason} ->
        {:stop, reason}
    end
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
    suppress_legacy? = CommandLifecycle.suppress_legacy_output?(state, event)

    state =
      state
      |> maybe_refresh_client_info(event.name)
      |> CommandLifecycle.process_event(event)
      |> JoinReconciliation.reconcile_event(event)

    cond do
      JoinReconciliation.failure_event?(event) ->
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
     |> JoinLifecycle.schedule_flush()}
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
    {:noreply, CommandLifecycle.fail_all(state, "Connection closed before completion.")}
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
         join_flush_timer: JoinLifecycle.cancel_flush(state),
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
      |> JoinLifecycle.flush()

    {:noreply, state}
  rescue
    Ecto.NoResultsError -> {:stop, :normal, state}
    Ecto.StaleEntryError -> {:stop, :normal, state}
  catch
    :exit, _reason -> {:noreply, %{state | join_flush_timer: nil}}
  end

  def handle_info({:flush_pending_joins, _token}, state), do: {:noreply, state}

  def handle_info(
        {:ircxd, {:privmsg, %{target: _target, nick: _nick, body: _body} = payload}},
        state
      ) do
    {:noreply, InboundMessageRouting.privmsg(state, payload)}
  end

  def handle_info(
        {:ircxd, {:notice, %{target: _target, nick: _nick, body: _body} = payload}},
        state
      ) do
    {:noreply, InboundMessageRouting.notice(state, payload)}
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
    normalized = Targets.key(state, channel)
    names_buffers = Map.get(state, :names_buffers, %{})
    buffered_names = Map.get(names_buffers, normalized, []) ++ names

    state = Map.put(state, :names_buffers, Map.put(names_buffers, normalized, buffered_names))

    state =
      if MapSet.member?(Map.get(state, :pending_joins, MapSet.new()), normalized) or
           Identity.listed?(names, state.connection.nickname) do
        JoinLifecycle.mark_joined(state, channel)
      else
        state
      end

    {:noreply, state}
  end

  def handle_info({:ircxd, {:names_end, %{channel: channel}}}, state) do
    normalized = Targets.key(state, channel)
    names_buffers = Map.get(state, :names_buffers, %{})
    names = Map.get(names_buffers, normalized, [])

    if names != [] do
      Presence.sync(state.connection, channel, names, Targets.casemapping(state))
    end

    state =
      state
      |> Map.put(:names_buffers, Map.delete(names_buffers, normalized))
      |> JoinLifecycle.mark_joined_from_names(channel, names)

    {:noreply, state}
  end

  def handle_info({:ircxd, {:join, %{channel: channel, nick: nick} = payload}}, state) do
    self? = Identity.source_self?(state, payload, nick)

    if self? do
      {:ok, _membership} =
        Chat.confirm_channel_join(
          state.connection,
          channel,
          Targets.casemapping(state),
          "connected"
        )
    end

    Presence.diff(
      state.connection,
      channel,
      %{action: "join", user: %{nick: nick, role: "user", status: "online"}},
      Targets.casemapping(state)
    )

    record_channel_line(state, channel, "join", nick, "#{nick} joined #{channel}.")

    state =
      if self? do
        JoinLifecycle.mark_joined(state, channel)
      else
        state
      end

    {:noreply, state}
  end

  def handle_info({:ircxd, {:part, %{channel: channel, nick: nick} = payload}}, state) do
    self? = Identity.source_self?(state, payload, nick)

    Presence.diff(
      state.connection,
      channel,
      %{action: "part", nick: nick},
      Targets.casemapping(state)
    )

    record_channel_line(state, channel, "part", nick, "#{nick} left #{channel}.")

    state =
      if self? do
        {:ok, _membership} =
          Chat.confirm_channel_left(state.connection, channel, Targets.casemapping(state))

        %{
          state
          | joined_channels: MapSet.delete(state.joined_channels, Targets.key(state, channel))
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

    Presence.diff(state.connection, nil, %{action: "quit", nick: nick})
    {:noreply, state}
  end

  def handle_info(
        {:ircxd, {:nick, %{old_nick: old_nick, new_nick: new_nick} = payload}},
        state
      ) do
    self? = Identity.source_self?(state, payload, old_nick)

    record_channel_line_for_present_nick(
      state.connection,
      "nick",
      old_nick,
      new_nick,
      fn _membership -> "#{old_nick} is now #{new_nick}." end
    )

    Presence.diff(state.connection, nil, %{
      action: "nick",
      old_nick: old_nick,
      new_nick: new_nick
    })

    unless self? do
      DirectMessageRenamer.rename(
        state.connection,
        old_nick,
        new_nick,
        EventFormatting.sender_metadata(payload),
        Targets.casemapping(state)
      )
    end

    state =
      if self? do
        case ConnectionLifecycle.update_nickname(state.connection, new_nick, "connected") do
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

    Presence.diff(state.connection, nil, %{
      action: "away",
      nick: nick,
      status: status
    })

    {:noreply, state}
  end

  def handle_info({:ircxd, {:mode, %{target: target} = payload}}, state) do
    if Targets.channel?(state, target) do
      payload
      |> EventFormatting.mode_presence_diffs(Targets.isupport(state))
      |> Enum.each(
        &Presence.diff(
          state.connection,
          target,
          &1,
          Targets.casemapping(state)
        )
      )

      record_channel_line(
        state,
        target,
        "mode",
        Map.get(payload, :nick),
        EventFormatting.mode_body(payload)
      )
    else
      record_server_line(state.connection, EventFormatting.mode_body(payload), "mode")
    end

    {:noreply, state}
  end

  def handle_info(
        {:ircxd, {:kick, %{channel: channel, nick: nick, target_nick: target_nick} = payload}},
        state
      ) do
    target_self? = Identity.event_self?(state, payload, :target_self?, target_nick)

    Presence.diff(
      state.connection,
      channel,
      %{action: "part", nick: target_nick},
      Targets.casemapping(state)
    )

    record_channel_line(
      state,
      channel,
      "kick",
      nick,
      EventFormatting.kick_body(payload)
    )

    state =
      if target_self? do
        case Chat.confirm_channel_left(state.connection, channel, Targets.casemapping(state)) do
          {:ok, _membership} ->
            %{
              state
              | joined_channels: MapSet.delete(state.joined_channels, Targets.key(state, channel))
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
    state = JoinReconciliation.reconcile_legacy_error(state, payload)
    record_irc_error(state, payload)
    {:noreply, state}
  end

  def handle_info(
        {:ircxd, {:standard_reply, %{type: :fail, command: "JOIN"} = payload}},
        state
      ) do
    pending? = JoinReconciliation.pending_command?(state)
    state = JoinReconciliation.reconcile_standard_failure(state, payload)

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
    {:noreply, CommandLifecycle.timeout(state, command_id)}
  end

  def handle_info({:command_grace_timeout, command_id}, state) do
    {:noreply, CommandLifecycle.grace_timeout(state, command_id)}
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
    with :ok <- JoinLifecycle.validate(state, channel) do
      if MapSet.member?(state.pending_joins, Targets.key(state, channel)) do
        {:reply, :ok, state}
      else
        {reply, state} = JoinLifecycle.transmit(state, channel)
        reply = if reply in [:sent, :queued], do: :ok, else: reply
        {:reply, reply, state}
      end
    else
      {:error, error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:request_join, user, channel}, _from, state) do
    key = Targets.key(state, channel)

    if MapSet.member?(state.pending_joins, key) do
      case Chat.get_channel_membership(state.connection, channel, Targets.casemapping(state)) do
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
      with :ok <- JoinLifecycle.validate(state, channel),
           {:ok, membership} <-
             Chat.request_channel_join(
               user,
               state.connection,
               channel,
               Targets.casemapping(state)
             ) do
        {reply, state} = JoinLifecycle.transmit(state, membership.channel)

        case reply do
          status when status in [:sent, :queued] ->
            {:reply, {:ok, membership, status}, state}

          error ->
            Chat.reject_channel_join(
              state.connection,
              membership.channel,
              error,
              Targets.casemapping(state)
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
    with :ok <- CommandLifecycle.validate_id(command_id, state),
         {:ok, client} <- fetch_registered_client(state),
         :ok <- prepare_managed_command(state, intent),
         {:ok, invocation} <- record_command_invocation(state, intent, command_id, buffer_id),
         {message, labeled?} <- CommandLifecycle.label(intent.message, command_id, state) do
      case Ircxd.Client.transmit(client, message) do
        :ok ->
          {state, managed_outcome} = persist_managed_outcome(state, intent)

          state =
            CommandLifecycle.track(
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

          {:reply, {:error, CommandLifecycle.execution_error(reason)}, state}
      end
    else
      {:error, %{code: _code} = error} -> {:reply, {:error, error}, state}
      {:error, reason} -> {:reply, {:error, CommandLifecycle.execution_error(reason)}, state}
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
        Targets.casemapping(state)
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
        Targets.casemapping(state)
      )

      {:reply, :ok, remember_pending_echo(state, channel, body, "action")}
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:privmsg_thread, thread_id, body}, _from, state) do
    with {:ok, client} <- fetch_client(state),
         {:ok, %{thread: thread, message: message}} <-
           DirectMessageSender.send(
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
    key = Targets.key(state, channel)

    if not MapSet.member?(state.joined_channels, key) and MapSet.member?(state.pending_joins, key) and
         not MapSet.member?(Map.get(state, :sent_joins, MapSet.new()), key) do
      case Chat.confirm_channel_left(state.connection, channel, Targets.casemapping(state)) do
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

  def handle_call(:quit_for_deletion, _from, state) do
    result =
      case state.client do
        nil -> :ok
        client -> Ircxd.Client.quit(client, "connection deleted")
      end

    {:stop, :normal, normalize_result(result), Map.put(state, :deleting?, true)}
  end

  @impl true
  def terminate(_reason, %{deleting?: true}), do: :ok

  def terminate(_reason, %{connection: connection} = state) do
    CommandLifecycle.fail_all(state, "IRC session stopped before completion.")
    update_status(connection, "disconnected")
    :ok
  end

  defp update_status(connection, status) do
    connection =
      if status == "connected" do
        case ConnectionLifecycle.touch_connected(connection) do
          {:ok, updated} -> updated
          {:error, _changeset} -> connection
        end
      else
        connection
      end

    ConnectionLifecycle.broadcast_status(connection, status)
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
      Targets.casemapping(state)
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
    if channel = Targets.channel(state, target) do
      Chat.record_channel_system_message(
        state.connection,
        channel,
        "error",
        nil,
        irc_error_body(payload),
        %{},
        Targets.casemapping(state)
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

  defp irc_error_body(%{reason: reason}) when is_binary(reason), do: reason
  defp irc_error_body(%{code: code}), do: "IRC error #{code}."
  defp irc_error_body(_payload), do: "IRC error."

  defp fetch_client(%{client: nil}), do: {:error, :not_connected}
  defp fetch_client(%{client: client}), do: {:ok, client}

  defp fetch_registered_client(%{registered?: true} = state), do: fetch_client(state)
  defp fetch_registered_client(_state), do: {:error, :not_connected}

  defp maybe_record_membership_failure(%Event{name: name, payload: payload}, state)
       when name in [:irc_error, :error],
       do: record_irc_error(state, payload)

  defp maybe_record_membership_failure(%Event{}, _state), do: :ok

  defp prepare_managed_command(
         state,
         %{disposition: :managed, message: %{command: "JOIN", params: [channels | _rest]}}
       ) do
    channels
    |> String.split(",", trim: true)
    |> Enum.reduce_while(:ok, fn channel, :ok ->
      cond do
        not Targets.channel?(state, channel) ->
          {:halt, {:error, :invalid_channel}}

        MapSet.member?(state.joined_channels, Targets.key(state, channel)) ->
          {:halt, {:error, :already_joined}}

        MapSet.member?(state.pending_joins, Targets.key(state, channel)) ->
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
      if Targets.channel?(state, target) and
           not MapSet.member?(state.joined_channels, Targets.key(state, target)) do
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
    if Targets.channel?(state, target), do: validate_joined_targets(state, target), else: :ok
  end

  defp prepare_managed_command(_state, _intent), do: :ok

  defp validate_joined_targets(state, targets) do
    targets
    |> String.split(",", trim: true)
    |> Enum.reduce_while(:ok, fn target, :ok ->
      if MapSet.member?(state.joined_channels, Targets.key(state, target)),
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
       |> Enum.any?(&(not Targets.channel?(state, &1))) do
      "#{command} #{targets} :[private message redacted]"
    else
      display
    end
  end

  defp command_invocation_display(_state, intent), do: intent.display

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
          Chat.request_channel_join(
            user,
            state.connection,
            channel,
            Targets.casemapping(current_state)
          )

        key = Targets.key(current_state, membership.channel)

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
            if channel = Targets.channel(current_state, target) do
              Chat.record_inbound_message(
                current_state.connection,
                channel,
                current_state.connection.nickname,
                body,
                kind,
                metadata,
                Targets.casemapping(current_state)
              )

              direct_messages
            else
              case DirectMessageIngestion.record(
                     current_state.connection,
                     target,
                     current_state.connection.nickname,
                     body,
                     kind,
                     metadata,
                     Targets.casemapping(current_state)
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

  defp parse_visible_users(value) when is_integer(value), do: value

  defp parse_visible_users(value) when is_binary(value) do
    case Integer.parse(value) do
      {count, ""} -> count
      _other -> 0
    end
  end

  defp parse_visible_users(_value), do: 0

  defp fetch_joined_client(state, channel) do
    normalized = Targets.key(state, channel)

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

  defp remember_pending_echo(state, target, body, kind) do
    pending_echoes =
      PendingEchoes.remember(
        state.pending_echoes,
        Targets.normalize(state, target),
        body,
        kind
      )

    %{state | pending_echoes: pending_echoes}
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
    JoinLifecycle.restore(state, info)
  catch
    :exit, _reason -> Map.put(state, :client_info, nil)
  end

  defp persist_casemapping(connection, casemapping) do
    mapping = Atom.to_string(casemapping)

    if connection.casemapping == mapping do
      connection
    else
      {:ok, updated} = Chat.update_connection_casemapping(connection, casemapping)
      {:ok, _losers} = MembershipReconciler.reconcile(updated, casemapping)
      updated
    end
  end

  defp finalize_registration_support(%{isupport_seen?: true, client_info: %Info{} = info} = state) do
    connection = persist_casemapping(state.connection, info.casemapping)
    mapping = info.casemapping

    state
    |> Map.put(:connection, connection)
    |> Map.put(:active_casemapping, mapping)
    |> JoinLifecycle.rekey(mapping)
    |> Map.put(:isupport_received?, true)
    |> Map.put(:join_validation_ready?, true)
    |> Map.put(:join_flush_timer, JoinLifecycle.cancel_flush(state))
    |> JoinLifecycle.flush()
  end

  defp finalize_registration_support(state) do
    state
    |> Map.put(:join_validation_ready?, true)
    |> Map.put(:join_flush_timer, JoinLifecycle.cancel_flush(state))
    |> JoinLifecycle.flush()
  end

  defp present?(value), do: is_binary(value) and value != ""

  defp start_payload(requested_connection) do
    ConnectionLock.run(requested_connection, fn ->
      case authoritative_connection(requested_connection) do
        %ServerConnection{} = connection ->
          pending_channels = JoinLifecycle.persisted_channels(connection)
          maybe_pause_start_after_lookup(connection)
          {connection, pending_channels}

        nil ->
          nil
      end
    end)
  end

  defp authoritative_connection(%ServerConnection{id: id, user_id: user_id}) do
    ServerConnection
    |> where(
      [connection],
      connection.id == ^id and connection.user_id == ^user_id and not connection.deleting
    )
    |> Repo.one()
  end

  defp maybe_pause_start_after_lookup(connection) do
    case Application.get_env(:ircpipe, :session_start_after_lookup_barrier) do
      {test_pid, barrier_ref} when is_pid(test_pid) ->
        test_ref = Process.monitor(test_pid)
        send(test_pid, {:session_start_paused, self(), barrier_ref, connection.id})

        receive do
          {:continue_session_start, ^barrier_ref} ->
            Process.demonitor(test_ref, [:flush])
            :ok

          {:DOWN, ^test_ref, :process, ^test_pid, _reason} ->
            :ok
        end

      _not_paused ->
        :ok
    end
  end

  defp legacy_event_name(name) when is_atom(name), do: Atom.to_string(name)
  defp legacy_event_name(event) when is_tuple(event), do: event |> elem(0) |> to_string()
  defp legacy_event_name(_event), do: "unknown"
end
