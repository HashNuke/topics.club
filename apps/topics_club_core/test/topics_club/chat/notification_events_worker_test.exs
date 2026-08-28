defmodule TopicsClub.Chat.NotificationEventsWorkerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias TopicsClub.Chat.NotificationEventsWorker

  test "returns a retryable error while the internal event adapter is unavailable" do
    previous_adapter = Application.get_env(:topics_club_core, :internal_event_adapter)
    Application.delete_env(:topics_club_core, :internal_event_adapter)

    on_exit(fn -> restore_env(:internal_event_adapter, previous_adapter) end)

    job = %Oban.Job{
      args: %{
        "notification_id" => 7,
        "user_id" => 42,
        "occurred_at" => "2026-08-28T10:11:12Z"
      }
    }

    capture_log(fn ->
      assert {:snooze, {1, :minute}} = NotificationEventsWorker.perform(job)
    end)
  end

  defp restore_env(key, nil), do: Application.delete_env(:topics_club_core, key)
  defp restore_env(key, value), do: Application.put_env(:topics_club_core, key, value)
end
