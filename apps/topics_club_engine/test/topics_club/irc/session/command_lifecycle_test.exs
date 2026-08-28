defmodule TopicsClub.Irc.Session.CommandLifecycleTest do
  use ExUnit.Case, async: true

  alias TopicsClub.Irc.Session.CommandLifecycle
  alias Ircxd.Client.Info
  alias Ircxd.Message

  test "validates bounded unique command identifiers" do
    state = %{pending_commands: %{"already-used" => %{}}}

    assert CommandLifecycle.validate_id("whois:mira-1", state) == :ok
    assert CommandLifecycle.validate_id("already-used", state) == {:error, :duplicate_command_id}
    assert CommandLifecycle.validate_id("", state) == {:error, :invalid_command_id}
    assert CommandLifecycle.validate_id("has spaces", state) == {:error, :invalid_command_id}

    assert CommandLifecycle.validate_id(String.duplicate("a", 65), state) ==
             {:error, :invalid_command_id}

    assert CommandLifecycle.validate_id(nil, state) == {:error, :invalid_command_id}
  end

  test "labels commands only when labeled-response is active" do
    message = %Message{command: "WHOIS", params: ["mira"], tags: %{}}

    labeled_state = %{
      client_info: struct(Info, active_caps: MapSet.new(["labeled-response"]))
    }

    assert {%Message{tags: %{"label" => "command-1"}}, true} =
             CommandLifecycle.label(message, "command-1", labeled_state)

    assert {^message, false} = CommandLifecycle.label(message, "command-1", %{})
  end

  test "tracks correlation targets and application terminal events" do
    message = %Message{command: "NICK", params: ["[Mira]"], tags: %{}}

    intent = %{
      spec: %{family: :mutation, result_events: [], terminal_events: []}
    }

    state = %{active_casemapping: :rfc1459, pending_commands: %{}}
    invocation = %{id: 42}

    tracked =
      CommandLifecycle.track(
        state,
        intent,
        message,
        invocation,
        "nick-1",
        "server:7",
        false
      )

    pending = tracked.pending_commands["nick-1"]
    assert pending.targets == ["{mira}"]
    assert pending.spec.terminal_events == [:nick]
    assert pending.command == "NICK"
    assert pending.invocation == invocation
    assert is_reference(pending.timer)

    Process.cancel_timer(pending.timer)
  end

  test "does not track commands without labeled, result, or terminal events" do
    message = %Message{command: "PING", params: ["server"], tags: %{}}
    intent = %{spec: %{family: :query, result_events: [], terminal_events: []}}
    state = %{active_casemapping: :ascii, pending_commands: %{}}

    assert CommandLifecycle.track(
             state,
             intent,
             message,
             %{id: 1},
             "ping-1",
             "server:7",
             false
           ) == state
  end

  test "suppresses legacy MOTD output while a correlated MOTD is pending" do
    event = Ircxd.Client.Event.from_legacy!({:motd, %{text: "hello"}})

    assert CommandLifecycle.suppress_legacy_output?(
             %{pending_commands: %{"motd-1" => %{command: "MOTD"}}},
             event
           )

    refute CommandLifecycle.suppress_legacy_output?(%{pending_commands: %{}}, event)
  end
end
