defmodule Ircpipe.InternalEventTest do
  use ExUnit.Case, async: true

  alias Ircpipe.InternalEvent
  alias Ircpipe.InternalEvent.Data

  test "accepts every version-one event type as a plain envelope" do
    occurred_at = ~U[2026-08-28 10:11:12Z]

    Enum.each(InternalEvent.types(), fn type ->
      assert {:ok, event} =
               InternalEvent.new(type, 42, %{committed_id: 7},
                 event_id: "event:#{type}:7",
                 occurred_at: occurred_at
               )

      assert event == %{
               version: 1,
               event_id: "event:#{type}:7",
               type: type,
               occurred_at: "2026-08-28T10:11:12Z",
               user_id: 42,
               data: %{committed_id: 7}
             }

      assert :ok = InternalEvent.validate(event)
    end)
  end

  test "rejects malformed envelopes and runtime values" do
    valid =
      InternalEvent.new!("message_committed", 42, %{message_id: 7},
        event_id: "message:7",
        occurred_at: ~U[2026-08-28 10:11:12Z]
      )

    assert {:error, :invalid_event} = InternalEvent.validate(%{valid | version: 2})
    assert {:error, :invalid_event} = InternalEvent.validate(%{valid | type: "browser_event"})
    assert {:error, :invalid_event} = InternalEvent.validate(%{valid | event_id: "bad id"})
    assert {:error, :invalid_event} = InternalEvent.validate(Map.put(valid, :extra, true))

    assert {:error, :invalid_event} =
             InternalEvent.validate(%{valid | data: %{timestamp: DateTime.utc_now()}})

    assert {:error, :invalid_event} = InternalEvent.validate(%{valid | data: %{pid: self()}})
  end

  test "canonical data keeps false values and converts timestamps to plain strings" do
    assert Data.connection(%{
             id: 7,
             user_id: 42,
             name: "libera",
             host: "irc.example.test",
             port: 6697,
             use_tls: false,
             nickname: "mira",
             status: "connected",
             desired_state: "connected",
             mention_notifications_enabled: false,
             notification_preference_revision: 3
           }) == %{
             id: 7,
             user_id: 42,
             name: "libera",
             host: "irc.example.test",
             port: 6697,
             use_tls: false,
             nickname: "mira",
             status: "connected",
             desired_state: "connected",
             mention_notifications_enabled: false,
             notification_preference_revision: 3
           }

    assert Data.presence_diff(%{
             action: "join",
             user: %{nick: "mira", last_observed_at: ~U[2026-08-28 10:11:12Z]}
           }) == %{
             action: "join",
             user: %{nick: "mira", last_observed_at: "2026-08-28T10:11:12Z"}
           }
  end
end
