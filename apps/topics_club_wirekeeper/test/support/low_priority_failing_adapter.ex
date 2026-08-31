defmodule TopicsClub.Wirekeeper.LowPriorityFailingAdapter do
  @moduledoc false

  @behaviour TopicsClub.Wirekeeper.ProtocolAdapter

  @impl true
  def init(_opts) do
    Process.flag(:priority, :low)
    {:error, :forced_failure}
  end

  @impl true
  def handle_inbound(data, state), do: {:ok, [{:forward, data}], state}
end
