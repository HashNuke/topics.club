defmodule TopicsClub.Wirekeeper.ProtocolAdapter.Passthrough do
  @moduledoc """
  Forwards each inbound socket chunk without interpreting it.

  Detached chunks are still discarded and counted by the connection owner.
  """

  @behaviour TopicsClub.Wirekeeper.ProtocolAdapter

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_inbound(data, state) when is_binary(data) do
    {:ok, [{:forward, data}], state}
  end
end
