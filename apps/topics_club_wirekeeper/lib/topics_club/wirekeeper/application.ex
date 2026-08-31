defmodule TopicsClub.Wirekeeper.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    TopicsClub.Wirekeeper.Supervisor.start_link([])
  end
end
