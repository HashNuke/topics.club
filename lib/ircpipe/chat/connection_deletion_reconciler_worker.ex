defmodule Ircpipe.Chat.ConnectionDeletionReconcilerWorker do
  @moduledoc false

  use Oban.Worker,
    queue: :connection_deletions,
    max_attempts: 20,
    unique: [period: 50, states: :incomplete]

  import Ecto.Query

  alias Ircpipe.Chat.{
    ConnectionDeletionEventBatch,
    ConnectionDeletionEventsWorker,
    ConnectionDeletionWorker,
    ServerConnection
  }

  alias Ircpipe.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    Repo.transaction(fn ->
      requeue_deletions()
      requeue_event_batches()
    end)

    :ok
  end

  defp requeue_deletions do
    ServerConnection
    |> where([connection], connection.deleting)
    |> select([connection], {connection.user_id, connection.id})
    |> Repo.all()
    |> Enum.each(fn {user_id, connection_id} ->
      %{user_id: user_id, connection_id: connection_id}
      |> ConnectionDeletionWorker.new()
      |> Oban.insert!()
    end)
  end

  defp requeue_event_batches do
    ConnectionDeletionEventBatch
    |> select([event_batch], event_batch.id)
    |> Repo.all()
    |> Enum.each(fn event_batch_id ->
      %{event_batch_id: event_batch_id}
      |> ConnectionDeletionEventsWorker.new()
      |> Oban.insert!()
    end)
  end
end
