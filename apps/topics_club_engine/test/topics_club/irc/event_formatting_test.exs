defmodule TopicsClub.Irc.EventFormattingTest do
  use ExUnit.Case, async: true

  alias TopicsClub.Irc.EventFormatting

  test "extracts sender identity metadata and the strongest prefixed role" do
    assert EventFormatting.sender_metadata(%{
             account: "akash-account",
             raw_source: "akash!user@example.test",
             prefixes: ["+", "@"]
           }) == %{
             account: "akash-account",
             hostmask: "akash!user@example.test",
             sender_role: "op"
           }

    assert EventFormatting.sender_metadata(%{prefixes: :unknown}) == %{
             account: nil,
             hostmask: nil,
             sender_role: nil
           }
  end

  test "turns channel role modes into ordered presence diffs while consuming other arguments" do
    assert EventFormatting.mode_presence_diffs(
             %{
               modes: "+b-o+v",
               params: ["*!*@blocked.test", "alice", "bob"]
             },
             %{}
           ) == [
             %{action: "role", nick: "alice", role: "user"},
             %{action: "role", nick: "bob", role: "voice"}
           ]

    assert EventFormatting.mode_presence_diffs(
             %{modes: "-l+q", params: ["carol"]},
             %{"PREFIX" => "(qaohv)~&@%+"}
           ) == [
             %{action: "role", nick: "carol", role: "owner"}
           ]

    assert EventFormatting.mode_presence_diffs(%{}, %{}) == []
  end

  test "uses negotiated CHANMODES to consume custom arguments before role modes" do
    isupport = %{
      "CHANMODES" => "beI,kfL,lj,psmntirRcOAQKVCuzNSMTGZ",
      "PREFIX" => "(ov)@+"
    }

    assert EventFormatting.mode_presence_diffs(
             %{modes: "+f-o", params: ["5:10", "alice"]},
             isupport
           ) == [
             %{action: "role", nick: "alice", role: "user"}
           ]
  end

  test "renders mode and kick activity with server fallbacks" do
    assert EventFormatting.mode_body(%{nick: "mira", modes: "+ov", params: ["a", "b"]}) ==
             "mira set mode +ov a b."

    assert EventFormatting.mode_body(%{nick: nil, modes: "+i", params: []}) ==
             "server set mode +i."

    assert EventFormatting.kick_body(%{
             nick: "mira",
             target_nick: "akash",
             reason: "too loud"
           }) == "akash was kicked by mira: too loud"

    assert EventFormatting.kick_body(%{nick: "", target_nick: "akash", reason: ""}) ==
             "akash was kicked by server."
  end

  test "identifies service senders and unwraps CTCP actions" do
    assert EventFormatting.service_name("NickServ") == "NickServ"
    assert EventFormatting.service_name("nickserv") == nil
    assert EventFormatting.service_name(nil) == nil

    assert EventFormatting.action_body({:ok, %{command: "ACTION", params: "waves"}}) ==
             {:ok, "waves"}

    assert EventFormatting.action_body({:ok, %{command: "VERSION", params: ""}}) == :error
    assert EventFormatting.action_body(:error) == :error
  end
end
