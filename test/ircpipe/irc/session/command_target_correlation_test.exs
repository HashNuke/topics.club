defmodule Ircpipe.Irc.Session.CommandTargetCorrelationTest do
  use ExUnit.Case, async: true

  alias Ircpipe.Irc.Session.CommandTargetCorrelation
  alias Ircxd.Message

  test "collects and canonicalizes multi-target command targets" do
    state = %{active_casemapping: :rfc1459}

    assert CommandTargetCorrelation.for_message(
             state,
             message("JOIN", ["#[One],&[Two]"])
           ) == ["\#{one}", "&{two}"]

    assert CommandTargetCorrelation.for_message(
             state,
             message("PRIVMSG", ["#[Room],[Mira]", "hello"])
           ) == ["\#{room}", "{mira}"]
  end

  test "collects targets for mutation and query command shapes" do
    state = %{active_casemapping: :rfc1459}

    assert CommandTargetCorrelation.for_message(state, message("NICK", ["[Mira]"])) == [
             "{mira}"
           ]

    assert CommandTargetCorrelation.for_message(
             state,
             message("ISON", ["[Mira]", "Zed"])
           ) == ["{mira}", "zed"]

    assert CommandTargetCorrelation.for_message(
             state,
             message("WHOIS", ["remote.example", "[Mira]"])
           ) == ["{mira}"]

    assert CommandTargetCorrelation.for_message(state, message("WHOIS", [])) == []
    assert CommandTargetCorrelation.for_message(state, message("QUIT", ["bye"])) == []
  end

  test "matches candidates using the same canonical target rules" do
    state = %{active_casemapping: :rfc1459}

    assert CommandTargetCorrelation.matches?(state, "\#{OPS}", ["\#{ops}"])
    assert CommandTargetCorrelation.matches?(state, "[Mira]", ["{mira}"])
    refute CommandTargetCorrelation.matches?(state, "Zed", ["{mira}"])
    refute CommandTargetCorrelation.matches?(state, nil, ["{mira}"])
  end

  defp message(command, params), do: %Message{command: command, params: params, tags: %{}}
end
