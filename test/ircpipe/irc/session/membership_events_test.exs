defmodule Ircpipe.Irc.Session.MembershipEventsTest do
  use ExUnit.Case, async: true

  alias Ircpipe.Chat.ServerConnection
  alias Ircpipe.Irc.Session
  alias Ircpipe.Irc.Session.MembershipEvents

  test "buffers split NAMES replies and marks a pending channel joined" do
    state = state_fixture(MapSet.new(["#elixir"]))

    state =
      MembershipEvents.handle(:names, state, %{
        channel: "#Elixir",
        names: [%{nick: "akash"}]
      })

    state =
      MembershipEvents.handle(:names, state, %{
        channel: "#Elixir",
        names: [%{nick: "MIRA"}]
      })

    assert state.names_buffers == %{
             "#elixir" => [%{nick: "akash"}, %{nick: "MIRA"}]
           }

    assert state.pending_joins == MapSet.new()
    assert state.joined_channels == MapSet.new(["#elixir"])
  end

  test "does not infer a join from unrelated NAMES" do
    state = state_fixture(MapSet.new())

    assert MembershipEvents.handle(:names, state, %{
             channel: "#Elixir",
             names: [%{nick: "akash"}]
           }).joined_channels == MapSet.new()
  end

  test "partial membership event payloads use the ignored-event path" do
    partial_events = [
      {:names, %{channel: "#elixir"}},
      {:names_end, %{}},
      {:join, %{channel: "#elixir"}},
      {:part, %{nick: "akash"}},
      {:quit, %{}},
      {:nick, %{old_nick: "akash"}},
      {:away, %{}},
      {:mode, %{}},
      {:kick, %{channel: "#elixir", nick: "operator"}},
      {:topic, %{channel: "#elixir", nick: "akash"}}
    ]

    state =
      Enum.reduce(partial_events, %{ignored_event_logs: %{}}, fn event, state ->
        assert {:noreply, next_state} = Session.handle_info({:ircxd, event}, state)
        next_state
      end)

    assert state.ignored_event_logs |> Map.keys() |> Enum.sort() ==
             ~w(away join kick mode names names_end nick part quit topic)
  end

  defp state_fixture(pending_joins) do
    %{
      connection: %ServerConnection{nickname: "mira"},
      active_casemapping: :ascii,
      names_buffers: %{},
      pending_joins: pending_joins,
      joined_channels: MapSet.new(),
      sent_joins: MapSet.new()
    }
  end
end
