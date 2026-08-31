defmodule TopicsClub.Wirekeeper.Supervisor do
  @moduledoc false

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: TopicsClub.Wirekeeper.ConnectionRegistry},
      {TopicsClub.Wirekeeper.ConnectionSupervisor, []},
      {Task.Supervisor, name: TopicsClub.Wirekeeper.OpenTaskSupervisor},
      {TopicsClub.Wirekeeper.Manager, []}
    ]

    Supervisor.init(children, strategy: :rest_for_one, max_restarts: 20, max_seconds: 5)
  end
end
