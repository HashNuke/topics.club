defmodule TopicsClub.Wirekeeper.BlockingConsumerWatcher do
  @moduledoc false

  def start(connection, consumer, opts) do
    owner = Keyword.fetch!(opts, :owner)

    spawn_monitor(fn ->
      send(owner, {:wirekeeper_blocking_consumer_watcher, self(), connection, consumer})

      receive do
        :finish -> :ok
      end
    end)
  end
end
