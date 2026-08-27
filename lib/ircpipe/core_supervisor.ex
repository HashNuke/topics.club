defmodule Ircpipe.CoreSupervisor do
  @moduledoc false

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      Ircpipe.Vault,
      Ircpipe.Repo,
      {Phoenix.PubSub, name: Ircpipe.PubSub}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
