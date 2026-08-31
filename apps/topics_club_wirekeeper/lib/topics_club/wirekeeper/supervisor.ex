defmodule TopicsClub.Wirekeeper.Supervisor do
  @moduledoc false

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      {TopicsClub.Wirekeeper.ConnectionSupervisor, []},
      {TopicsClub.Wirekeeper.Manager, []}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
