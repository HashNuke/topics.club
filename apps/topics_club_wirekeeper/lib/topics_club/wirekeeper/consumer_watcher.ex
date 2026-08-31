defmodule TopicsClub.Wirekeeper.ConsumerWatcher do
  @moduledoc false

  @spec start(pid(), pid(), keyword()) :: {pid(), reference()}
  def start(connection, consumer, _opts) do
    spawn_monitor(fn -> watch(connection, consumer) end)
  end

  defp watch(connection, consumer) do
    connection_ref = Process.monitor(connection)
    consumer_ref = Process.monitor(consumer)

    receive do
      {:DOWN, ^consumer_ref, :process, ^consumer, reason} ->
        send(
          connection,
          {:topics_club_wirekeeper_consumer_down, self(), consumer, reason}
        )

      {:DOWN, ^connection_ref, :process, ^connection, _reason} ->
        :ok
    end
  end
end
