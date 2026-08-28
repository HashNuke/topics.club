defmodule IrcpipeWeb.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    IrcpipeWeb.Supervisor.start_link([])
  end

  @impl true
  def config_change(changed, _new, removed) do
    IrcpipeWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
