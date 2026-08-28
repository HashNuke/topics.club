defmodule TopicsClub.Irc.Session.JoinLifecycleTest do
  use ExUnit.Case, async: true

  alias TopicsClub.Chat.ServerConnection
  alias TopicsClub.Irc.Session.JoinLifecycle

  test "queues a join until the registered client is ready" do
    state = %{
      active_casemapping: :ascii,
      client: nil,
      joined_channels: MapSet.new(),
      pending_joins: MapSet.new(),
      sent_joins: MapSet.new()
    }

    assert {:queued, queued} = JoinLifecycle.transmit(state, "#Elixir")
    assert MapSet.member?(queued.pending_joins, "#elixir")
    assert queued.sent_joins == MapSet.new()
  end

  test "treats an already joined channel as sent without changing state" do
    state = %{
      active_casemapping: :ascii,
      joined_channels: MapSet.new(["#elixir"]),
      pending_joins: MapSet.new(),
      sent_joins: MapSet.new()
    }

    assert JoinLifecycle.transmit(state, "#Elixir") == {:sent, state}
  end

  test "marks a channel joined and clears pending and sent tracking" do
    state = %{
      active_casemapping: :ascii,
      joined_channels: MapSet.new(),
      pending_joins: MapSet.new(["#elixir"]),
      sent_joins: MapSet.new(["#elixir"])
    }

    joined = JoinLifecycle.mark_joined(state, "#Elixir")

    assert joined.joined_channels == MapSet.new(["#elixir"])
    assert joined.pending_joins == MapSet.new()
    assert joined.sent_joins == MapSet.new()
  end

  test "marks a channel joined from NAMES only for a pending join or listed self nick" do
    state = %{
      active_casemapping: :ascii,
      connection: %ServerConnection{nickname: "mira"},
      joined_channels: MapSet.new(),
      pending_joins: MapSet.new(),
      sent_joins: MapSet.new()
    }

    assert JoinLifecycle.mark_joined_from_names(state, "#room", ["someone"]) == state

    joined = JoinLifecycle.mark_joined_from_names(state, "#room", [%{nick: "MIRA"}])
    assert MapSet.member?(joined.joined_channels, "#room")
  end

  test "rekeys all runtime channel sets when casemapping changes" do
    state = %{
      pending_joins: MapSet.new(["#[room]"]),
      joined_channels: MapSet.new(["#[joined]"]),
      sent_joins: MapSet.new(["#[sent]"])
    }

    rekeyed = JoinLifecycle.rekey(state, :rfc1459)

    assert rekeyed.pending_joins == MapSet.new(["\#{room}"])
    assert rekeyed.joined_channels == MapSet.new(["\#{joined}"])
    assert rekeyed.sent_joins == MapSet.new(["\#{sent}"])
  end

  test "schedules and cancels the ISUPPORT settle flush" do
    state = %{registered?: true, join_validation_ready?: false, join_flush_timer: nil}
    scheduled = JoinLifecycle.schedule_flush(state)

    assert {timer, token} = scheduled.join_flush_timer
    assert is_reference(timer)
    assert is_reference(token)
    assert JoinLifecycle.cancel_flush(scheduled) == nil
  end
end
