defmodule Ircpipe.ClosedIrcSession do
  use GenServer

  alias Ircpipe.Irc.SessionLocator

  def child_spec(connection) do
    %{
      id: {__MODULE__, connection.user_id, connection.id},
      start: {__MODULE__, :start_link, [connection]},
      restart: :temporary
    }
  end

  def start_link(connection) do
    GenServer.start_link(__MODULE__, connection, name: SessionLocator.via(connection))
  end

  @impl true
  def init(connection), do: {:ok, connection}

  @impl true
  def handle_call({:quit, _reason}, _from, connection) do
    {:reply, {:error, :closed}, connection}
  end
end
