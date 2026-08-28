defmodule Ircpipe.Irc.Session.EventDispatcherTest do
  use ExUnit.Case, async: true

  alias Ircpipe.Irc.Session.EventDispatcher
  alias Ircxd.Client.Event

  test "routes an unknown IRC event through unhandled-event tracking" do
    state = %{ignored_event_logs: %{}}

    dispatched = EventDispatcher.dispatch(state, {:future_event, %{value: 1}})

    assert Map.has_key?(dispatched.ignored_event_logs, "future_event")
  end

  test "dispatches a canonical event through its legacy representation" do
    state = %{ignored_event_logs: %{}, pending_commands: %{}}

    event =
      struct(Event,
        name: :future_event,
        derivative?: true,
        legacy: {:future_event, %{value: 1}}
      )

    dispatched = EventDispatcher.dispatch(state, event)

    assert Map.has_key?(dispatched.ignored_event_logs, "future_event")
  end
end
