defmodule TopicsClub.Engine.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    TopicsClub.EngineSupervisor.start_link([])
  end
end
