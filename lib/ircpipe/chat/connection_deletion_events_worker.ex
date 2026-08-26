defmodule Ircpipe.Chat.ConnectionDeletionEventsWorker do
  @moduledoc false

  use Oban.Worker,
    queue: :connection_deletions,
    max_attempts: 20,
    unique: [
      period: :infinity,
      keys: [:event_batch_id],
      states: :incomplete
    ]

  import Ecto.Query

  alias Ircpipe.Chat.{BufferEvents, ConnectionDeletionEventBatch}
  alias Ircpipe.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"event_batch_id" => event_batch_id}}) do
    dispatch(event_batch_id)
  end

  def dispatch(event_batch_id) when is_integer(event_batch_id) do
    case Repo.get(ConnectionDeletionEventBatch, event_batch_id) do
      nil ->
        :ok

      batch ->
        batch.payloads
        |> Map.fetch!("events")
        |> Enum.each(&broadcast(batch.user_id, &1))

        _deleted_count =
          ConnectionDeletionEventBatch
          |> where([event_batch], event_batch.id == ^batch.id)
          |> Repo.delete_all()

        :ok
    end
  end

  defp broadcast(user_id, payload) do
    BufferEvents.left(%{
      user_id: user_id,
      buffer_id: Map.fetch!(payload, "buffer_id"),
      server_connection_id: Map.fetch!(payload, "server_connection_id"),
      channel_membership_id: Map.fetch!(payload, "channel_membership_id"),
      event_id: Map.fetch!(payload, "event_id"),
      occurred_at: parse_occurred_at(Map.fetch!(payload, "occurred_at"))
    })
  end

  defp parse_occurred_at(occurred_at) do
    case DateTime.from_iso8601(occurred_at) do
      {:ok, parsed, 0} -> parsed
      _invalid -> occurred_at
    end
  end
end
