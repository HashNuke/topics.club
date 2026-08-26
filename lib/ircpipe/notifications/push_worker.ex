defmodule Ircpipe.Notifications.PushWorker do
  use Oban.Worker,
    queue: :notifications,
    max_attempts: 5,
    unique: [period: :infinity, keys: [:notification_id]]

  alias Ircpipe.Notifications

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"notification_id" => notification_id}}) do
    Notifications.deliver_notification(notification_id)
  end
end
