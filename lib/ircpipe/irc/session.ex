defmodule Ircpipe.Irc.Session do
  use GenServer

  require Logger

  alias Ircpipe.Chat
  alias Ircpipe.Chat.ConnectionLifecycle
  alias Ircpipe.Irc.Session.CommandLifecycle
  alias Ircpipe.Irc.Session.CommandExecution
  alias Ircpipe.Irc.Session.ChannelListRequest
  alias Ircpipe.Irc.Session.ClientOptions
  alias Ircpipe.Irc.Session.EventRecorder
  alias Ircpipe.Irc.Session.InboundMessageRouting
  alias Ircpipe.Irc.Session.JoinLifecycle
  alias Ircpipe.Irc.Session.JoinReconciliation
  alias Ircpipe.Irc.Session.MembershipEvents
  alias Ircpipe.Irc.Session.OutboundMessages
  alias Ircpipe.Irc.Session.PendingEchoes
  alias Ircpipe.Irc.Session.Registration
  alias Ircpipe.Irc.Session.ServerEvents
  alias Ircpipe.Irc.Session.StartupAuthorization
  alias Ircpipe.Irc.Session.Targets
  alias Ircpipe.Chat.{ChannelMembership, CommandMessages, ServerConnection}
  alias Ircpipe.Accounts.User
  alias Ircxd.Message
  alias Ircxd.Client.{Event, Info}

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
    GenServer.call(via(connection), :list_channels, ChannelListRequest.timeout_ms() + 1_000)
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

    case Ircxd.Client.start_link(ClientOptions.build(connection, self())) do
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

  def handle_info({:ircxd, {event, %{text: _text} = payload}}, state)
      when event in [
             :welcome,
             :your_host,
             :server_created,
             :motd_start,
             :motd,
             :motd_end,
             :motd_missing
           ],
      do: {:noreply, ServerEvents.handle(event, state, payload)}

  def handle_info({:ircxd, {:server_info, payload}}, state) do
    {:noreply, ServerEvents.handle(:server_info, state, payload)}
  end

  def handle_info({:ircxd, {:names, %{channel: _channel, names: _names} = payload}}, state),
    do: {:noreply, MembershipEvents.handle(:names, state, payload)}

  def handle_info({:ircxd, {:names_end, %{channel: _channel} = payload}}, state),
    do: {:noreply, MembershipEvents.handle(:names_end, state, payload)}

  def handle_info({:ircxd, {:join, %{channel: _channel, nick: _nick} = payload}}, state),
    do: {:noreply, MembershipEvents.handle(:join, state, payload)}

  def handle_info({:ircxd, {:part, %{channel: _channel, nick: _nick} = payload}}, state),
    do: {:noreply, MembershipEvents.handle(:part, state, payload)}

  def handle_info({:ircxd, {:quit, %{nick: _nick} = payload}}, state),
    do: {:noreply, MembershipEvents.handle(:quit, state, payload)}

  def handle_info(
        {:ircxd, {:nick, %{old_nick: _old_nick, new_nick: _new_nick} = payload}},
        state
      ),
      do: {:noreply, MembershipEvents.handle(:nick, state, payload)}

  def handle_info({:ircxd, {:away, %{nick: _nick} = payload}}, state),
    do: {:noreply, MembershipEvents.handle(:away, state, payload)}

  def handle_info({:ircxd, {:mode, %{target: _target} = payload}}, state),
    do: {:noreply, MembershipEvents.handle(:mode, state, payload)}

  def handle_info(
        {:ircxd, {:kick, %{channel: _channel, nick: _nick, target_nick: _target_nick} = payload}},
        state
      ),
      do: {:noreply, MembershipEvents.handle(:kick, state, payload)}

  def handle_info(
        {:ircxd, {:topic, %{channel: _channel, nick: _nick, topic: _topic} = payload}},
        state
      ),
      do: {:noreply, MembershipEvents.handle(:topic, state, payload)}

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
    {:noreply, ServerEvents.handle(:nick_in_use, state, payload)}
  end

  def handle_info({:ircxd, {:list_start, _payload}}, %{channel_list_request: request} = state)
      when not is_nil(request) do
    {:noreply, %{state | channel_list_request: ChannelListRequest.reset(request)}}
  end

  def handle_info(
        {:ircxd, {:list_entry, %{channel: _channel} = payload}},
        %{channel_list_request: request} = state
      )
      when not is_nil(request) do
    {:noreply, %{state | channel_list_request: ChannelListRequest.add(request, payload)}}
  end

  def handle_info({:ircxd, {:list_end, _payload}}, %{channel_list_request: request} = state)
      when not is_nil(request) do
    {:noreply, %{state | channel_list_request: ChannelListRequest.complete(request)}}
  end

  def handle_info(
        {:channel_list_timeout, ref},
        %{channel_list_request: %{ref: ref} = request} = state
      ) do
    {:noreply, %{state | channel_list_request: ChannelListRequest.expire(request)}}
  end

  def handle_info({:channel_list_timeout, _ref}, state), do: {:noreply, state}

  def handle_info({:command_timeout, command_id}, state) do
    {:noreply, CommandLifecycle.timeout(state, command_id)}
  end

  def handle_info({:command_grace_timeout, command_id}, state) do
    {:noreply, CommandLifecycle.grace_timeout(state, command_id)}
  end

  def handle_info(
        {:ircxd, {:raw, %Message{command: command} = message}},
        state
      )
      when byte_size(command) == 3 do
    {:noreply, ServerEvents.handle(:raw, state, message)}
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
          CommandMessages.update(invocation, %{
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
      {:noreply, %{state | channel_list_request: ChannelListRequest.new(from)}}
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:say, channel, body}, _from, state) do
    {reply, state} = OutboundMessages.say(state, channel, body)
    {:reply, reply, state}
  end

  def handle_call({:action, channel, body}, _from, state) do
    {reply, state} = OutboundMessages.action(state, channel, body)
    {:reply, reply, state}
  end

  def handle_call({:privmsg_thread, thread_id, body}, _from, state) do
    {reply, state} = OutboundMessages.direct(state, thread_id, body)
    {:reply, reply, state}
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

  defp normalize_result(:ok), do: :ok
  defp normalize_result(error), do: error

  defp legacy_event_name(name) when is_atom(name), do: Atom.to_string(name)
  defp legacy_event_name(event) when is_tuple(event), do: event |> elem(0) |> to_string()
  defp legacy_event_name(_event), do: "unknown"
end
