defmodule TopicsClub.Irc.Session.IdentityTest do
  use ExUnit.Case, async: true

  alias TopicsClub.Chat.ServerConnection
  alias TopicsClub.Irc.Session.Identity
  alias Ircxd.Client.Info

  test "uses an authoritative event identity flag after ISUPPORT negotiation" do
    state = negotiated_state("mira", :ascii)

    refute Identity.event_self?(state, %{source_self?: false}, :source_self?, "mira")
    assert Identity.event_self?(state, %{source_self?: true}, :source_self?, "someone-else")
    assert Identity.event_self?(state, %{}, :source_self?, "MIRA")
  end

  test "ignores event flags before negotiation and compares against the stored nickname" do
    state = %{
      connection: %ServerConnection{nickname: "mira", casemapping: "ascii"},
      isupport_received?: false
    }

    assert Identity.event_self?(state, %{source_self?: false}, :source_self?, "MIRA")
    refute Identity.event_self?(state, %{source_self?: true}, :source_self?, "someone-else")
  end

  test "uses negotiated and stored IRC casemappings for self identity" do
    assert Identity.self?(negotiated_state("[Mira]", :rfc1459), "{mira}")

    rfc_state = %{
      connection: %ServerConnection{nickname: "[Mira]", casemapping: "rfc1459"},
      isupport_received?: false
    }

    ascii_state = put_in(rfc_state.connection.casemapping, "ascii")

    assert Identity.self?(rfc_state, "{mira}")
    refute Identity.self?(ascii_state, "{mira}")
    refute Identity.self?(rfc_state, nil)
  end

  test "detects the current nickname across supported NAMES entry shapes" do
    names = [%{nick: "ALICE"}, %{"nick" => "Bob"}, "Mira", %{invalid: "entry"}]

    assert Identity.listed?(names, "alice", :ascii)
    assert Identity.listed?(names, "BOB", :ascii)
    assert Identity.listed?(names, "mira", :ascii)
    refute Identity.listed?(names, "carol", :ascii)
    refute Identity.listed?(nil, "mira", :ascii)
  end

  test "detects listed nicknames with the negotiated IRC casemapping" do
    assert Identity.listed?([%{nick: "[Mira]"}], "{mira}", :rfc1459)
    assert Identity.listed?([%{nick: "mi^ra"}], "MI~RA", :rfc1459)
    refute Identity.listed?([%{nick: "[Mira]"}], "{mira}", :ascii)
    refute Identity.listed?([%{nick: "mi^ra"}], "MI~RA", :strict_rfc1459)
  end

  defp negotiated_state(current_nick, casemapping) do
    %{
      active_casemapping: casemapping,
      connection: %ServerConnection{nickname: "stored"},
      client_info: struct(Info, current_nick: current_nick),
      isupport_received?: true
    }
  end
end
