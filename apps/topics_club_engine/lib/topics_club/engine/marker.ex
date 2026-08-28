defmodule TopicsClub.Engine.Marker do
  @moduledoc false

  use GenServer

  require Logger

  alias TopicsClub.EngineClient.Discovery

  def start_link(opts) do
    name = Keyword.get(opts, :name, {:global, Discovery.marker_name()})

    case GenServer.start_link(__MODULE__, opts, name: name) do
      {:error, {:already_started, owner}} = error ->
        Logger.error("IRC engine ownership is already held",
          owner_node: node(owner),
          attempted_node: node()
        )

        :telemetry.execute(
          [:topics_club, :engine, :marker],
          %{system_time: System.system_time()},
          %{owner_node: node(owner), status: :duplicate}
        )

        error

      result ->
        result
    end
  end

  def status(server \\ {:global, Discovery.marker_name()}) do
    GenServer.call(server, :status)
  catch
    :exit, _reason -> %{owner_node: nil, started_at: nil, status: :unavailable}
  end

  @impl true
  def init(_opts) do
    state = %{started_at: DateTime.utc_now(:second) |> DateTime.to_iso8601()}
    Logger.info("Acquired IRC engine ownership", owner_node: node())

    :telemetry.execute(
      [:topics_club, :engine, :marker],
      %{system_time: System.system_time()},
      %{owner_node: node(), status: :acquired}
    )

    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, %{owner_node: Atom.to_string(node()), started_at: state.started_at, status: :owner},
     state}
  end
end
