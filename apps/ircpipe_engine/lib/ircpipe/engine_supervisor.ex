defmodule Ircpipe.EngineSupervisor do
  @moduledoc false

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      {Ircpipe.Engine.Marker, []},
      {Ircpipe.Engine.OperationLock, []},
      {Task.Supervisor, name: Ircpipe.Engine.RequestTaskSupervisor},
      {Oban, Application.fetch_env!(:ircpipe_engine, Ircpipe.EngineOban)},
      {Ircpipe.Irc.SessionSystemSupervisor, []},
      {Ircpipe.Irc.HostedServerSupervisor, []}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
