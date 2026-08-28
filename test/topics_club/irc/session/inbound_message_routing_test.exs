defmodule TopicsClub.Irc.Session.InboundMessageRoutingTest do
  use TopicsClub.DataCase, async: false

  alias TopicsClub.AccountsFixtures
  alias TopicsClub.Chat
  alias TopicsClub.Chat.{Connections, DirectMessageLifecycle, Message}
  alias TopicsClub.Irc.{Session, SessionLocator, SessionSupervisor}
  alias TopicsClub.Irc.Session.{InboundMessageRouting, PendingEchoes}
  alias TopicsClub.IrcTestServer
  alias TopicsClub.Repo
  alias Ircxd.Client.Info

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

  test "reconciles the stored nickname from an authoritative self message" do
    user = AccountsFixtures.user_fixture()
    connection = connection_fixture(user)
    {:ok, _membership} = Chat.join_channel(user, connection, "#elixir")
    Phoenix.PubSub.subscribe(TopicsClub.PubSub, "user:#{user.id}")

    state = %{
      connection: connection,
      active_casemapping: :rfc1459,
      client_info: struct(Info, current_nick: "mira_", casemapping: :rfc1459),
      isupport_received?: true,
      pending_echoes: PendingEchoes.new()
    }

    returned =
      InboundMessageRouting.privmsg(state, %{
        target: "#elixir",
        nick: "mira_",
        raw_source: "mira_!user@example.test",
        body: "authoritative self echo"
      })

    assert returned.connection.nickname == "mira_"
    assert Connections.get!(user, connection.id).nickname == "mira_"
    first_event = receive_user_event()
    assert {:server_status, %{nickname: "mira_", status: "connected"}} = first_event
    second_event = receive_user_event()
    assert {:buffer_message, %{body: "authoritative self echo", nick: "mira_"}} = second_event
  end

  test "reconciles persisted nickname drift even when the session snapshot already matches IRC" do
    user = AccountsFixtures.user_fixture()
    connection = connection_fixture(user)
    {:ok, _membership} = Chat.join_channel(user, connection, "#elixir")
    Phoenix.PubSub.subscribe(TopicsClub.PubSub, "user:#{user.id}")

    cached_connection = %{connection | nickname: "mira_"}
    connection |> Ecto.Changeset.change(nickname: "stale-edit") |> Repo.update!()

    state = %{
      connection: cached_connection,
      active_casemapping: :rfc1459,
      client_info: struct(Info, current_nick: "mira_", casemapping: :rfc1459),
      isupport_received?: true,
      pending_echoes: PendingEchoes.new()
    }

    returned =
      InboundMessageRouting.privmsg(state, %{
        target: "#elixir",
        nick: "mira_",
        raw_source: "mira_!user@example.test",
        body: "self echo after stale edit"
      })

    assert returned.connection.nickname == "mira_"
    assert Connections.get!(user, connection.id).nickname == "mira_"
    assert_receive {:server_status, %{nickname: "mira_", status: "connected"}}
    assert_receive {:buffer_message, %{body: "self echo after stale edit"}}
  end

  test "deduplicates a self echo addressed through a channel status prefix" do
    user = AccountsFixtures.user_fixture()
    connection = connection_fixture(user)
    {:ok, _membership} = Chat.join_channel(user, connection, "##fix_your_connection")

    state = %{
      connection: connection,
      active_casemapping: :rfc1459,
      client_info:
        struct(Info,
          current_nick: "mira",
          casemapping: :rfc1459,
          isupport: %{"CHANTYPES" => "#", "STATUSMSG" => "@+"}
        ),
      isupport_received?: true,
      pending_echoes:
        PendingEchoes.new()
        |> PendingEchoes.remember(
          "##fix_your_connection",
          "Msgs appear twice",
          "message"
        )
    }

    returned =
      InboundMessageRouting.privmsg(state, %{
        target: "@##fix_your_connection",
        nick: "mira",
        raw_source: "mira!user@example.test",
        body: "Msgs appear twice"
      })

    assert PendingEchoes.empty?(returned.pending_echoes)
    refute Repo.get_by(Message, body: "Msgs appear twice")
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

  defp receive_user_event do
    receive do
      {:server_status, _payload} = event -> event
      {:buffer_message, _payload} = event -> event
      _unrelated_message -> receive_user_event()
    after
      100 -> flunk("expected a user PubSub event")
    end
  end
end
