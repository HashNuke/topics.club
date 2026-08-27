defmodule Ircpipe.Irc.Session.InboundMessageRoutingTest do
  use Ircpipe.DataCase, async: false

  alias Ircpipe.AccountsFixtures
  alias Ircpipe.Chat.{Connections, DirectMessageLifecycle, Message}
  alias Ircpipe.Irc.{Session, SessionLocator, SessionSupervisor}
  alias Ircpipe.Irc.Session.{InboundMessageRouting, PendingEchoes}
  alias Ircpipe.IrcTestServer
  alias Ircpipe.Repo

  test "routes a user private message into a direct-message buffer" do
    user = AccountsFixtures.user_fixture()
    connection = connection_fixture(user)
    state = %{connection: connection, pending_echoes: PendingEchoes.new()}

    payload = %{
      target: connection.nickname,
      nick: "akash",
      raw_source: "akash!user@example.test",
      body: "hello privately"
    }

    assert InboundMessageRouting.privmsg(state, payload) == state

    assert [thread] = DirectMessageLifecycle.list(user, connection)
    assert thread.peer_nick == "akash"
    assert thread.unread_count == 1
  end

  test "drops channel PRIVMSG and NOTICE lines when their membership is missing" do
    user = AccountsFixtures.user_fixture()
    connection = connection_fixture(user)

    state = %{
      connection: connection,
      active_casemapping: :ascii,
      pending_echoes: PendingEchoes.new()
    }

    privmsg = %{
      target: "#missing",
      nick: "akash",
      raw_source: "akash!user@example.test",
      body: "late private message"
    }

    notice = %{
      target: "#missing",
      nick: "irc.example.test",
      raw_source: "irc.example.test",
      body: "late notice"
    }

    assert InboundMessageRouting.privmsg(state, privmsg) == state
    assert InboundMessageRouting.notice(state, notice) == state
    refute Repo.get_by(Message, body: "late private message")
    refute Repo.get_by(Message, body: "late notice")
  end

  test "keeps the session alive when late channel messages arrive without a membership" do
    server = start_supervised!({IrcTestServer, self()})
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(user, %{
        "name" => "late-channel-routing",
        "host" => "127.0.0.1",
        "port" => IrcTestServer.port(server),
        "use_tls" => false,
        "nickname" => "mira"
      })

    on_exit(fn -> SessionSupervisor.stop_session(connection) end)

    assert {:ok, _pid} = SessionSupervisor.start_session(connection)
    assert_receive {:irc_server_line, "NICK mira"}, 1_000
    assert_receive {:irc_server_line, "USER mira 0 * mira"}, 1_000

    assert :ok =
             IrcTestServer.send_line(
               server,
               ":akash!user@example.test PRIVMSG #gone :late private message"
             )

    assert :ok =
             IrcTestServer.send_line(
               server,
               ":irc.example.test NOTICE #gone :late notice"
             )

    assert :ok = IrcTestServer.send_line(server, "PING :late-membership-check")
    assert_receive {:irc_server_line, "PONG late-membership-check"}, 1_000
    assert {:ok, _info} = Session.connection_info(connection)
    _ = :sys.get_state(SessionLocator.via(connection))

    refute Repo.get_by(Message, body: "late private message")
    refute Repo.get_by(Message, body: "late notice")
    assert :ok = Session.quit(connection)
  end

  defp connection_fixture(user) do
    {:ok, connection} =
      Connections.create(user, %{
        "name" => "routing-test",
        "host" => "irc.example.com",
        "nickname" => "mira"
      })

    connection
  end
end
