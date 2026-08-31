defmodule TopicsClub.Wirekeeper.Delivery do
  @moduledoc false

  @spec send(pid(), term()) :: :ok | :nosuspend | :noconnect
  def send(consumer, message) do
    :erlang.send(consumer, message, [:nosuspend, :noconnect])
  end
end
