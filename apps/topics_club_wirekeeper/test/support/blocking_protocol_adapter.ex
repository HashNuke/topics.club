defmodule TopicsClub.Wirekeeper.BlockingProtocolAdapter do
  @moduledoc false

  @behaviour TopicsClub.Wirekeeper.ProtocolAdapter

  @impl true
  def init(opts) do
    owner = Keyword.fetch!(opts, :owner)
    send(owner, {:wirekeeper_blocking_adapter, :init_started, self()})

    receive do
      :continue_wirekeeper_adapter_init -> {:ok, %{}}
    end
  end

  @impl true
  def handle_inbound(data, state), do: {:ok, [{:forward, data}], state}
end
