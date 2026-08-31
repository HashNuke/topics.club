defmodule TopicsClub.Wirekeeper.ProtocolAdapter.IrcKeepaliveTest do
  use ExUnit.Case, async: true

  alias TopicsClub.Wirekeeper.ProtocolAdapter.IrcKeepalive

  test "answers fragmented tagged and prefixed PING lines without forwarding them" do
    assert {:ok, state} = IrcKeepalive.init([])

    assert {:ok, [], state} =
             IrcKeepalive.handle_inbound("@label=42 :irc.example PI", state)

    assert {:ok, [{:reply, "PONG :keepalive-token\r\n"}], _state} =
             IrcKeepalive.handle_inbound("NG :keepalive-token\r\n", state)
  end

  test "forwards complete non-PING IRC lines unchanged" do
    assert {:ok, state} = IrcKeepalive.init([])
    notice = ":irc.example NOTICE nick :PING is only text\r\n"
    privmsg = ":friend!user@example PRIVMSG #elixir :hello\r\n"

    assert {:ok, [{:forward, ^notice}, {:forward, ^privmsg}], _state} =
             IrcKeepalive.handle_inbound(notice <> privmsg, state)
  end

  test "rejects an unterminated line that exceeds the configured bound" do
    assert {:ok, state} = IrcKeepalive.init(max_line_bytes: 8)

    assert {:error, :line_too_long, _state} =
             IrcKeepalive.handle_inbound("123456789", state)
  end
end
