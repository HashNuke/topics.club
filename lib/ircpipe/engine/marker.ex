defmodule Ircpipe.Engine.Marker do
  @moduledoc false

  use GenServer

  alias Ircpipe.EngineClient.Discovery

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: {:global, Discovery.marker_name()})
  end

  @impl true
  def init(_opts), do: {:ok, %{started_at: System.system_time(:second)}}
end
