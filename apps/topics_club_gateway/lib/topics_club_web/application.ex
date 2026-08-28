defmodule TopicsClubWeb.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    TopicsClubWeb.Supervisor.start_link([])
  end

  @impl true
  def config_change(changed, _new, removed) do
    TopicsClubWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
