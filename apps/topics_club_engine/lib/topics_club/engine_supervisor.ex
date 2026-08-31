defmodule TopicsClub.EngineSupervisor do
  @moduledoc false

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      {TopicsClub.Engine.Marker, []},
      {TopicsClub.Engine.OperationLock, []},
      {Task.Supervisor, name: TopicsClub.Engine.RequestTaskSupervisor},
      {Oban, Application.fetch_env!(:topics_club_engine, TopicsClub.EngineOban)},
      {TopicsClub.Irc.ConnectionOperationLock, []},
      {TopicsClub.Irc.ChannelListCache, []},
      {TopicsClub.Irc.SessionSystemSupervisor, []},
      {TopicsClub.Irc.Bouncer, []},
      {TopicsClub.Irc.HostedServerSupervisor, []}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
