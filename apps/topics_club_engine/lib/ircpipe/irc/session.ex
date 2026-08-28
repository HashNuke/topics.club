defmodule Ircpipe.Irc.Session do
  use GenServer

  alias Ircpipe.Irc.Session.CallRouting
  alias Ircpipe.Irc.Session.ChannelListEvents
  alias Ircpipe.Irc.Session.ChannelListRequest
  alias Ircpipe.Irc.Session.ClientLifecycle
  alias Ircpipe.Irc.Session.CommandLifecycle
  alias Ircpipe.Irc.Session.ConnectionEvents
  alias Ircpipe.Irc.Session.EventDispatcher
  alias Ircpipe.Irc.Session.Initialization
  alias Ircpipe.Irc.Session.JoinFlush
  alias Ircpipe.Irc.SessionLocator
  alias Ircpipe.Chat.ServerConnection
  alias Ircpipe.Accounts.User

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
