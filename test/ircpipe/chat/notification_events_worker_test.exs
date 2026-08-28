defmodule Ircpipe.Chat.NotificationEventsWorkerTest do
  use ExUnit.Case, async: false

  alias Ircpipe.Chat.NotificationEventsWorker

  @tag :capture_log
  test "returns a retryable error while the internal event adapter is unavailable" do
    previous_adapter = Application.get_env(:ircpipe, :internal_event_adapter)
    Application.delete_env(:ircpipe, :internal_event_adapter)

    on_exit(fn -> restore_env(:internal_event_adapter, previous_adapter) end)

    job = %Oban.Job{
      args: %{
        "notification_id" => 7,
        "user_id" => 42,
        "occurred_at" => "2026-08-28T10:11:12Z"
      }
    }

    assert {:snooze, {1, :minute}} = NotificationEventsWorker.perform(job)
  end

  defp restore_env(key, nil), do: Application.delete_env(:ircpipe, key)
  defp restore_env(key, value), do: Application.put_env(:ircpipe, key, value)
end
