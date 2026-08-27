defmodule Ircpipe.FailingIrcClient do
  use GenServer

  def start_link(reason) do
    GenServer.start_link(__MODULE__, reason)
  end

  @impl true
  def init(reason), do: {:ok, reason}

  @impl true
  def handle_call({:send, "JOIN", [_channel]}, _from, reason) do
    {:reply, {:error, reason}, reason}
  end
end
