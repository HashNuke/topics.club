defmodule TopicsClub.Chat.NotificationEventsWorker do
  @moduledoc false

  use Oban.Worker,
    queue: :internal_events,
    max_attempts: 20,
    unique: [
      period: :infinity,
      keys: [:notification_id],
      states: :incomplete
    ]

  alias TopicsClub.InternalEvents

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{
          "notification_id" => notification_id,
          "user_id" => user_id,
          "occurred_at" => occurred_at
        }
      }) do
    case InternalEvents.emit(
           "notification_committed",
           user_id,
           %{notification_id: notification_id},
           event_id: "notification:#{notification_id}",
           occurred_at: occurred_at
         ) do
      :ok -> :ok
      {:ok, _result} -> :ok
      {:error, _reason} -> {:snooze, {1, :minute}}
    end
  end
end
