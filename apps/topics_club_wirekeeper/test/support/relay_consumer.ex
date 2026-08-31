defmodule TopicsClub.Wirekeeper.RelayConsumer do
  @moduledoc false

  use GenServer

  def start_link(owner) do
    GenServer.start_link(__MODULE__, owner)
  end

  @impl true
  def init(owner), do: {:ok, owner}

  @impl true
  def handle_info(message, owner) do
    send(owner, {:relay_consumer, self(), message})
    {:noreply, owner}
  end
end
