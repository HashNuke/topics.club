defmodule TopicsClub.Irc.Session.EventDispatcherTest do
  use ExUnit.Case, async: true

  alias TopicsClub.Irc.Session.EventDispatcher
  alias TopicsClub.Chat.ServerConnection
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

  @tag capture_log: true
  test "does not turn a failed nick change on an established connection into a connection failure" do
    state = %{
      connection: %ServerConnection{id: -1, user_id: -1, nickname: "mira"},
      ignored_event_logs: %{},
      pending_commands: %{},
      registered?: true
    }

    assert EventDispatcher.dispatch(
             state,
             {:nick_in_use, %{attempted: "taken", reason: "Nickname is already in use"}}
           ) == state

    refute_receive :halt_for_connection_issue
  end
end
