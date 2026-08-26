defmodule Ircpipe.Irc.SessionSystemSupervisor do
  @moduledoc false

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      {Ircpipe.Irc.SingleNodeGuard, []},
      {Registry, keys: :unique, name: Ircpipe.Irc.SessionRegistry},
      {Ircpipe.Irc.SessionSupervisor, []},
      {Ircpipe.Irc.Bouncer, []}
    ]

    Supervisor.init(children, strategy: :one_for_all, max_restarts: 100, max_seconds: 10)
  end
end
