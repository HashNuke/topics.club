defmodule TopicsClub.Irc.Session.PendingEchoesTest do
  use ExUnit.Case, async: true

  alias TopicsClub.Irc.Session.PendingEchoes

  test "remembers and consumes one matching echo" do
    pending_echoes =
      PendingEchoes.new()
      |> PendingEchoes.remember("#elixir", "hello", "message", 1_000)

    assert {:matched, %PendingEchoes{} = pending_echoes} =
             PendingEchoes.pop(pending_echoes, "#elixir", "hello", "message", 1_001)

    assert PendingEchoes.empty?(pending_echoes)
  end

  test "leaves an unmatched echo available" do
    pending_echoes =
      PendingEchoes.new()
      |> PendingEchoes.remember("#elixir", "hello", "message", 1_000)

    assert {:unmatched, %PendingEchoes{} = pending_echoes} =
             PendingEchoes.pop(pending_echoes, "#elixir", "different", "message", 1_001)

    refute PendingEchoes.empty?(pending_echoes)
  end

  test "expires echoes after five minutes" do
    pending_echoes =
      PendingEchoes.new()
      |> PendingEchoes.remember("#elixir", "hello", "message", 1_000)

    six_minutes_later = 1_000 + :timer.minutes(6)

    assert {:unmatched, %PendingEchoes{} = pending_echoes} =
             PendingEchoes.pop(
               pending_echoes,
               "#elixir",
               "hello",
               "message",
               six_minutes_later
             )

    assert PendingEchoes.empty?(pending_echoes)
  end

  test "keeps only the 200 newest echoes" do
    pending_echoes =
      Enum.reduce(1..201, PendingEchoes.new(), fn index, pending_echoes ->
        PendingEchoes.remember(
          pending_echoes,
          "#elixir",
          "message #{index}",
          "message",
          index
        )
      end)

    assert {:unmatched, pending_echoes} =
             PendingEchoes.pop(pending_echoes, "#elixir", "message 1", "message", 202)

    assert {:matched, pending_echoes} =
             PendingEchoes.pop(pending_echoes, "#elixir", "message 201", "message", 202)

    refute PendingEchoes.empty?(pending_echoes)
  end
end
