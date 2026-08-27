defmodule Ircpipe.Irc.Session do
  use GenServer

  require Logger

  alias Ircpipe.Chat
  alias Ircpipe.Chat.Presence
  alias Ircpipe.Chat.ConnectionLifecycle
  alias Ircpipe.Chat.DirectMessageSender
  alias Ircpipe.Chat.DirectMessageRenamer
  alias Ircpipe.Chat.MessageIngestion
  alias Ircpipe.Irc.CommandRegistry
  alias Ircpipe.Irc.EventFormatting
  alias Ircpipe.Irc.Session.CommandLifecycle
  alias Ircpipe.Irc.Session.CommandExecution
  alias Ircpipe.Irc.Session.EventRecorder
  alias Ircpipe.Irc.Session.Identity
  alias Ircpipe.Irc.Session.InboundMessageRouting
  alias Ircpipe.Irc.Session.JoinLifecycle
  alias Ircpipe.Irc.Session.JoinReconciliation
  alias Ircpipe.Irc.Session.PendingEchoes
  alias Ircpipe.Irc.Session.Registration
  alias Ircpipe.Irc.Session.StartupAuthorization
  alias Ircpipe.Irc.Session.Targets
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
    case StartupAuthorization.load(requested_connection) do
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
    EventRecorder.server_line(connection, "Connecting to #{connection.host}:#{connection.port}.")
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

        EventRecorder.server_line(
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
      |> Registration.refresh(event.name)
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
    EventRecorder.server_line(updated, "Connected to #{updated.host}.")

    {:noreply,
     state
     |> Map.put(:connection, updated)
     |> Map.put(:registered?, true)
     |> Registration.refresh_client_info()
     |> JoinLifecycle.schedule_flush()}
  end

  def handle_info({:ircxd, {:connect_error, reason}}, state) do
    Logger.warning("IRC connection error for #{state.connection.host}: #{inspect(reason)}")

    EventRecorder.server_line(
      state.connection,
      "Connection error for #{state.connection.host}: #{inspect(reason)}.",
      "error"
    )

    update_status(state.connection, "errored")
    {:noreply, state}
  end

  def handle_info({:ircxd, :disconnected}, state) do
    EventRecorder.server_line(state.connection, "Disconnected from #{state.connection.host}.")
    update_status(state.connection, "disconnected")
    {:noreply, CommandLifecycle.fail_all(state, "Connection closed before completion.")}
  end

  def handle_info({:ircxd, {:reconnecting, _payload}}, state) do
    EventRecorder.server_line(
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
    EventRecorder.server_line(state.connection, text)
    {:noreply, state}
  end

  def handle_info({:ircxd, {:your_host, %{text: text}}}, state) do
    EventRecorder.server_line(state.connection, text)
    {:noreply, state}
  end

  def handle_info({:ircxd, {:server_created, %{text: text}}}, state) do
    EventRecorder.server_line(state.connection, text)
    {:noreply, state}
  end

  def handle_info({:ircxd, {:server_info, payload}}, state) do
    EventRecorder.server_line(
      state.connection,
      "#{payload.server} #{payload.version} user modes #{payload.user_modes} channel modes #{payload.channel_modes}",
      "notice"
    )

    {:noreply, state}
  end

  def handle_info({:ircxd, {:motd_start, %{text: text}}}, state) do
    EventRecorder.server_line(state.connection, text, "notice")
    {:noreply, state}
  end

  def handle_info({:ircxd, {:motd, %{text: text}}}, state) do
    EventRecorder.server_line(state.connection, text, "notice")
    {:noreply, state}
  end

  def handle_info({:ircxd, {:motd_end, %{text: text}}}, state) do
    EventRecorder.server_line(state.connection, text, "notice")
    {:noreply, state}
  end

  def handle_info({:ircxd, {:motd_missing, %{text: text}}}, state) do
    EventRecorder.server_line(state.connection, text, "notice")
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

    EventRecorder.channel_line(state, channel, "join", nick, "#{nick} joined #{channel}.")

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

    EventRecorder.channel_line(state, channel, "part", nick, "#{nick} left #{channel}.")

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
    EventRecorder.present_nick_line(state.connection, "quit", nick, fn _membership ->
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

    EventRecorder.present_nick_line(
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

      EventRecorder.channel_line(
        state,
        target,
        "mode",
        Map.get(payload, :nick),
        EventFormatting.mode_body(payload)
      )
    else
      EventRecorder.server_line(state.connection, EventFormatting.mode_body(payload), "mode")
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

    EventRecorder.channel_line(
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
    EventRecorder.channel_line(
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
    EventRecorder.irc_error(state, payload)
    {:noreply, state}
  end

  def handle_info(
        {:ircxd, {:standard_reply, %{type: :fail, command: "JOIN"} = payload}},
        state
      ) do
    pending? = JoinReconciliation.pending_command?(state)
    state = JoinReconciliation.reconcile_standard_failure(state, payload)

    unless pending? do
      EventRecorder.server_line(
        state.connection,
        Map.get(payload, :description) || "JOIN failed.",
        "error"
      )
    end

    {:noreply, state}
  end

  def handle_info({:ircxd, {:nick_in_use, payload}}, state) do
    reason = Map.get(payload, :reason) || "That nickname is already in use."
    EventRecorder.server_line(state.connection, reason, "error")
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

      EventRecorder.server_line(
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
         :ok <- CommandExecution.prepare(state, intent),
         {:ok, invocation} <-
           CommandExecution.record_invocation(state, intent, command_id, buffer_id),
         {message, labeled?} <- CommandLifecycle.label(intent.message, command_id, state) do
      case Ircxd.Client.transmit(client, message) do
        :ok ->
          {state, managed_outcome} = CommandExecution.persist_outcome(state, intent)

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
      MessageIngestion.record_channel(
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
      MessageIngestion.record_channel(
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

    EventRecorder.server_line(state.connection, "Disconnected from #{state.connection.host}.")
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

  defp fetch_client(%{client: nil}), do: {:error, :not_connected}
  defp fetch_client(%{client: client}), do: {:ok, client}

  defp fetch_registered_client(%{registered?: true} = state), do: fetch_client(state)
  defp fetch_registered_client(_state), do: {:error, :not_connected}

  defp maybe_record_membership_failure(%Event{name: name, payload: payload}, state)
       when name in [:irc_error, :error],
       do: EventRecorder.irc_error(state, payload)

  defp maybe_record_membership_failure(%Event{}, _state), do: :ok

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

  defp present?(value), do: is_binary(value) and value != ""

  defp legacy_event_name(name) when is_atom(name), do: Atom.to_string(name)
  defp legacy_event_name(event) when is_tuple(event), do: event |> elem(0) |> to_string()
  defp legacy_event_name(_event), do: "unknown"
end
