defmodule TopicsClub.Irc.Session do
  use GenServer

  alias TopicsClub.Irc.Session.CallRouting
  alias TopicsClub.Irc.Session.ChannelListEvents
  alias TopicsClub.Irc.Session.ChannelListRequest
  alias TopicsClub.Irc.Session.ClientLifecycle
  alias TopicsClub.Irc.Session.CommandLifecycle
  alias TopicsClub.Irc.Session.ConnectionEvents
  alias TopicsClub.Irc.Session.EventDispatcher
  alias TopicsClub.Irc.Session.Initialization
  alias TopicsClub.Irc.Session.JoinFlush
  alias TopicsClub.Irc.SessionLocator
  alias TopicsClub.Chat.ServerConnection
  alias TopicsClub.Accounts.User

  def child_spec(%ServerConnection{} = connection) do
    %{
      id: {__MODULE__, connection.user_id, connection.id},
      start: {__MODULE__, :start_link, [connection]},
      restart: :transient
    }
  end

  def start_link(%ServerConnection{} = connection) do
    GenServer.start_link(__MODULE__, connection, name: SessionLocator.via(connection))
  end

  def request_join(%ServerConnection{} = connection, %User{} = user, channel) do
    GenServer.call(SessionLocator.via(connection), {:request_join, user, channel})
  end

  def list_channels(%ServerConnection{} = connection) do
    GenServer.call(
      SessionLocator.via(connection),
      :list_channels,
      ChannelListRequest.timeout_ms() + 1_000
    )
  end

  def say(%ServerConnection{} = connection, channel, body) do
    GenServer.call(SessionLocator.via(connection), {:say, channel, body})
  end

  def action(%ServerConnection{} = connection, channel, body) do
    GenServer.call(SessionLocator.via(connection), {:action, channel, body})
  end

  def privmsg_thread(%ServerConnection{} = connection, thread_id, body) do
    GenServer.call(SessionLocator.via(connection), {:privmsg_thread, thread_id, body})
  end

  def part(%ServerConnection{} = connection, channel, reason \\ "") do
    GenServer.call(SessionLocator.via(connection), {:part, channel, reason})
  end

  def quit(%ServerConnection{} = connection, reason \\ "leaving") do
    GenServer.call(SessionLocator.via(connection), {:quit, reason})
  end

  def connection_info(%ServerConnection{} = connection) do
    GenServer.call(SessionLocator.via(connection), :connection_info)
  end

  def execute(%ServerConnection{} = connection, intent, command_id, buffer_id) do
    GenServer.call(
      SessionLocator.via(connection),
      {:execute, intent, command_id, buffer_id}
    )
  end

  @impl true
  def init(%ServerConnection{} = requested_connection) do
    Initialization.initialize(requested_connection)
  end

  @impl true
  def handle_info(:connect, state) do
    case ConnectionEvents.connect(state) do
      {:ok, state} -> {:noreply, state}
      {:stop, reason} -> {:stop, reason, state}
    end
  end

  def handle_info({:ircxd, event}, state), do: {:noreply, EventDispatcher.dispatch(state, event)}

  def handle_info(:halt_for_connection_issue, state),
    do: {:stop, :normal, %{state | preserve_error_status?: true}}

  def handle_info({:retry_connect, attempt}, state),
    do: ConnectionEvents.retry_connect(state, attempt)

  def handle_info({:DOWN, monitor_ref, :process, pid, reason}, state),
    do: ConnectionEvents.client_exited(state, monitor_ref, pid, reason)

  def handle_info({:flush_pending_joins, token}, state), do: JoinFlush.handle(state, token)

  def handle_info({:channel_list_timeout, ref}, state),
    do: {:noreply, ChannelListEvents.timeout(state, ref)}

  def handle_info({:command_timeout, command_id}, state) do
    {:noreply, CommandLifecycle.timeout(state, command_id)}
  end

  def handle_info({:command_grace_timeout, command_id}, state) do
    {:noreply, CommandLifecycle.grace_timeout(state, command_id)}
  end

  @impl true
  def handle_call(request, from, state), do: CallRouting.handle(request, from, state)

  @impl true
  def terminate(_reason, state) do
    :ok = ClientLifecycle.stop(state.client)
    _state = ConnectionEvents.terminate(state)
    :ok
  end
end
