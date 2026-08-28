defmodule IrcpipeWeb.Supervisor do
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
    discovery_enabled? =
      Keyword.get(
        opts,
        :discovery_enabled?,
        Application.get_env(:topics_club_gateway, :discovery_refresh_enabled, false)
      )

    [
      IrcpipeWeb.Telemetry,
      {Task.Supervisor, name: IrcpipeWeb.EngineRestoreTaskSupervisor},
      {IrcpipeWeb.EngineRestorer, []},
      {Oban, Application.fetch_env!(:topics_club_gateway, IrcpipeWeb.Oban)}
    ] ++
      discovery_children(discovery_enabled?) ++
      [
        IrcpipeWeb.Endpoint
      ]
  end

  @doc false
  def discovery_children(true), do: [{Ircpipe.Discovery.Refresher, []}]
  def discovery_children(false), do: []
end
