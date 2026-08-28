defmodule TopicsClub.CoreSupervisor do
  @moduledoc false

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    pubsub_pool_size = Application.fetch_env!(:topics_club_core, :pubsub_pool_size)

    children = [
      TopicsClub.Vault,
      TopicsClub.Repo,
      {Phoenix.PubSub, name: TopicsClub.PubSub, pool_size: pubsub_pool_size}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
