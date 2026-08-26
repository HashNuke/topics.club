defmodule Ircpipe.ClosedIrcSession do
  use GenServer

  alias Ircpipe.Irc.Session

  def start_link(connection) do
    GenServer.start_link(__MODULE__, connection, name: Session.via(connection))
  end

  @impl true
  def init(connection), do: {:ok, connection}

  @impl true
  def handle_call({:quit, _reason}, _from, connection) do
    {:reply, {:error, :closed}, connection}
  end
end
