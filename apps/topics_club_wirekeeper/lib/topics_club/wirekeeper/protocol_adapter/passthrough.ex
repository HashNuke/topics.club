defmodule TopicsClub.Wirekeeper.ProtocolAdapter.Passthrough do
  @moduledoc """
  Forwards each inbound socket chunk without interpreting it.

  Each transport chunk becomes one retained record. Protocols that require semantic message
  boundaries should provide a framing adapter instead.
  """

  @behaviour TopicsClub.Wirekeeper.ProtocolAdapter

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_inbound(data, state) when is_binary(data) do
    {:ok, [{:forward, data}], state}
  end
end
