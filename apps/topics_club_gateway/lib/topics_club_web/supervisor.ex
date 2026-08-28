defmodule TopicsClubWeb.Supervisor do
  @moduledoc false

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    Supervisor.init(children(opts), strategy: :one_for_one)
  end

  @doc false
  def children(opts \\ []) do
    engine_node =
      Keyword.get(
        opts,
        :engine_node,
        Application.get_env(:topics_club_gateway, :engine_node)
      )

    discovery_enabled? =
      Keyword.get(
        opts,
        :discovery_enabled?,
        Application.get_env(:topics_club_gateway, :discovery_refresh_enabled, false)
      )

    [
      TopicsClubWeb.Telemetry
    ] ++
      engine_node_children(engine_node) ++
      [
        {Task.Supervisor, name: TopicsClubWeb.EngineRestoreTaskSupervisor},
        {TopicsClubWeb.EngineRestorer, []},
        {Oban, Application.fetch_env!(:topics_club_gateway, TopicsClubWeb.Oban)}
      ] ++
      discovery_children(discovery_enabled?) ++
      [
        TopicsClubWeb.Endpoint
      ]
  end

  @doc false
  def engine_node_children(nil), do: []

  def engine_node_children(engine_node) when is_atom(engine_node) do
    [{TopicsClubWeb.EngineNodeConnector, engine_node: engine_node}]
  end

  @doc false
  def discovery_children(true), do: [{TopicsClub.Discovery.Refresher, []}]
  def discovery_children(false), do: []
end
