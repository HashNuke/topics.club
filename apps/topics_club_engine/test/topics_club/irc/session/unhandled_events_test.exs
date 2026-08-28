defmodule TopicsClub.Irc.Session.UnhandledEventsTest do
  use ExUnit.Case, async: true

  alias TopicsClub.Irc.Session.UnhandledEvents

  test "names and throttles repeated unhandled events" do
    first_state = UnhandledEvents.handle(%{ignored_event_logs: %{}}, {:future_event, %{}})
    second_state = UnhandledEvents.handle(first_state, {:future_event, %{changed: true}})

    assert Map.has_key?(first_state.ignored_event_logs, "future_event")
    assert second_state.ignored_event_logs == first_state.ignored_event_logs
  end

  test "uses stable names for atom and unknown event shapes" do
    state = UnhandledEvents.handle(%{}, :registered_elsewhere)
    state = UnhandledEvents.handle(state, %{unexpected: true})
    state = UnhandledEvents.handle(state, {})
    state = UnhandledEvents.handle(state, {%{}, :payload})
    state = UnhandledEvents.handle(state, {"draft-event", :payload})

    assert Map.has_key?(state.ignored_event_logs, "registered_elsewhere")
    assert Map.has_key?(state.ignored_event_logs, "unknown")
    assert Map.has_key?(state.ignored_event_logs, "draft-event")
  end
end
