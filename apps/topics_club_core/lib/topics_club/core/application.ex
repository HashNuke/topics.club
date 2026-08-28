defmodule TopicsClub.Core.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    TopicsClub.CoreSupervisor.start_link([])
  end
end
