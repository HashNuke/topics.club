defmodule Ircpipe.EngineSupervisor do
  @moduledoc false

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      {Oban, Application.fetch_env!(:ircpipe, Ircpipe.EngineOban)},
      {Ircpipe.Irc.SessionSystemSupervisor, []}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
