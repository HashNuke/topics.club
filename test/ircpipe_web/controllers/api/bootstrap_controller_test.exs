defmodule IrcpipeWeb.Api.BootstrapControllerTest do
  use IrcpipeWeb.ConnCase, async: false

  alias Ircpipe.AccountsFixtures
  alias Ircpipe.Chat
  alias Ircpipe.Chat.Presence
  alias Ircpipe.Chat.Connections
  alias Ircpipe.Chat.Topic
  alias Ircpipe.Irc.{Session, SessionSupervisor}
  alias Ircpipe.IrcTestServer
  alias Ircpipe.Repo

  setup :register_and_log_in_user

  test "requires authentication" do
    conn = build_conn() |> get(~p"/api/bootstrap")

    assert redirected_to(conn) == ~p"/users/log-in"
  end

  test "returns user-scoped bootstrap data", %{conn: conn, user: user} do
    other_user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(user, %{
        "name" => "local",
        "host" => "127.0.0.1",
        "port" => 6667,
        "use_tls" => false,
        "nickname" => "mira",
        "status" => "connected"
      })

    {:ok, membership} = Chat.join_channel(user, connection, "#elixir")
    {:ok, direct_message_thread} = Chat.open_direct_message(user, connection, "Zed")
    {:ok, archived_membership} = Chat.join_channel(user, connection, "#archive")
    Chat.record_inbound_message(connection, "#archive", "akash", "retained archive")
    {:ok, _archived_membership} = Chat.confirm_channel_left(connection, "#archive")
    {:ok, server_message} = Chat.record_server_message(connection, "Connected to local")

    {:ok, channel_message} =
      Chat.record_inbound_message(connection, "#elixir", "akash", "hello mira")

    Presence.sync(connection, "#elixir", [
      %{nick: "mira", prefixes: ["@"], raw_source: "mira!user@example.test"},
      %{nick: "akash", prefixes: []}
    ])

    {:ok, other_connection} =
      Connections.create(other_user, %{
        "name" => "other",
        "host" => "127.0.0.1",
        "port" => 6667,
        "use_tls" => false,
        "nickname" => "other"
      })

    {:ok, _other_membership} = Chat.join_channel(other_user, other_connection, "#private")

    Repo.insert!(
      Topic.changeset(%Topic{}, %{
        name: "#elixir",
        description: "Local Elixir discussion.",
        server_host: "127.0.0.1",
        server_port: 6667,
        use_tls: false,
        channel: "#elixir",
        sort_order: 10
      })
    )

    on_exit(fn -> SessionSupervisor.stop_session(connection) end)
    conn = get(conn, ~p"/api/bootstrap")

    assert %{
             "user" => %{"id" => user_id, "email" => _email, "message_retention_days" => 3},
             "push" => %{
               "configured" => false,
               "vapid_public_key" => nil,
               "session_generation" => session_generation,
               "session_registration_confirmed" => false,
               "session_installation_id" => nil
             },
             "command_catalog" => command_catalog,
             "server_time" => _server_time,
             "connections" => [connection_json],
             "buffers" => [server_buffer, direct_message_buffer, channel_buffer],
             "active_buffer_id" => active_buffer_id,
             "messages_by_buffer" => messages_by_buffer,
             "message_cursors_by_buffer" => message_cursors_by_buffer,
             "users_by_buffer" => users_by_buffer,
             "topics" => topics_json
           } = json_response(conn, 200)

    assert user_id == user.id
    assert is_binary(session_generation)
    assert connection_json["id"] == connection.id
    assert connection_json["channels"] == [membership.id]
    assert connection_json["direct_messages"] == [direct_message_thread.id]
    assert connection_json["mention_notifications_enabled"]
    assert Enum.any?(command_catalog, &(&1["name"] == "/quote"))

    assert server_buffer["buffer_id"] == "server:#{connection.id}"
    assert server_buffer["buffer_type"] == "server"
    assert server_buffer["title"] == "127.0.0.1"
    assert server_buffer["unread_count"] == 1
    assert server_buffer["mention_notifications_enabled"]

    direct_message_buffer_id = "direct:#{direct_message_thread.id}"
    direct_message_thread_id = direct_message_thread.id
    direct_message_revision = direct_message_thread.mutation_revision
    server_connection_id = connection.id

    assert %{
             "account" => nil,
             "blocked" => false,
             "buffer_id" => ^direct_message_buffer_id,
             "buffer_type" => "direct_message",
             "channel_membership_id" => nil,
             "closed_at" => nil,
             "direct_message_revision" => ^direct_message_revision,
             "direct_message_thread_id" => ^direct_message_thread_id,
             "hostmask" => nil,
             "mention_count" => 0,
             "peer_nick" => "Zed",
             "server_connection_id" => ^server_connection_id,
             "status" => direct_message_status,
             "subtitle" => "on 127.0.0.1",
             "title" => "Zed",
             "unread_count" => 0
           } = direct_message_buffer

    assert direct_message_status in ["connecting", "connected", "disconnected"]

    assert channel_buffer["buffer_id"] == "channel:#{membership.id}"
    assert channel_buffer["buffer_type"] == "channel"
    assert channel_buffer["channel_membership_id"] == membership.id
    assert channel_buffer["title"] == "#elixir"
    assert channel_buffer["unread_count"] == 1
    assert channel_buffer["mention_notifications_enabled"]

    channel_buffer_id = "channel:#{membership.id}"
    server_buffer_id = "server:#{connection.id}"

    assert active_buffer_id == channel_buffer_id
    assert message_cursors_by_buffer[server_buffer_id] == server_message.id

    assert [
             %{
               "body" => "Connected to local",
               "buffer_id" => ^server_buffer_id,
               "type" => "buffer:system",
               "version" => 1,
               "event_id" => "message:" <> _
             }
           ] =
             messages_by_buffer[server_buffer_id]

    assert server_message.channel_membership_id == nil

    assert [
             %{
               "body" => "hello mira",
               "buffer_id" => ^channel_buffer_id,
               "type" => "buffer:message",
               "version" => 1,
               "event_id" => "message:" <> _
             }
           ] =
             messages_by_buffer[channel_buffer_id]

    assert message_cursors_by_buffer[channel_buffer_id] == channel_message.id

    assert [
             %{
               "nick" => "akash",
               "role" => "user",
               "status" => "online",
               "last_observed_at" => _
             },
             %{
               "nick" => "mira",
               "role" => "op",
               "status" => "online",
               "hostmask" => "mira!user@example.test",
               "last_observed_at" => _
             }
           ] = users_by_buffer[channel_buffer_id]

    assert Enum.any?(
             topics_json,
             &match?(%{"channel" => "#elixir", "server_host" => "127.0.0.1"}, &1)
           )

    refute Enum.any?(get_in(json_response(conn, 200), ["buffers"]), &(&1["title"] == "#private"))

    refute Enum.any?(
             get_in(json_response(conn, 200), ["buffers"]),
             &(&1["channel_membership_id"] == archived_membership.id)
           )

    assert :ok = SessionSupervisor.stop_session(connection)
  end

  test "starts persisted IRC sessions and rejoins channels on bootstrap", %{
    conn: conn,
    user: user
  } do
    server = start_supervised!({IrcTestServer, self()})

    {:ok, connection} =
      Connections.create(user, %{
        "name" => "local",
        "host" => "127.0.0.1",
        "port" => IrcTestServer.port(server),
        "use_tls" => false,
        "nickname" => "mira",
        "status" => "disconnected"
      })

    {:ok, _membership} = Chat.join_channel(user, connection, "#elixir")

    conn = get(conn, ~p"/api/bootstrap")

    assert %{"connections" => [%{"id" => connection_id}]} = json_response(conn, 200)
    assert connection_id == connection.id

    assert_receive {:irc_server_line, "NICK mira"}, 1_000
    assert_receive {:irc_server_line, "USER mira 0 * mira"}, 1_000
    assert_receive {:irc_server_line, "JOIN #elixir"}, 1_000

    assert :ok = Session.quit(connection)
  end

  test "returns open direct-message buffers and their retained messages", %{
    conn: conn,
    user: user
  } do
    {:ok, connection} =
      Connections.create(user, %{
        "name" => "local",
        "host" => "127.0.0.1",
        "port" => 6667,
        "use_tls" => false,
        "nickname" => "mira"
      })

    assert {:ok, %{thread: thread, message: message}} =
             Chat.record_direct_message(
               connection,
               "akash",
               "akash",
               "hello privately",
               "message",
               %{direction: "incoming", account: "akash-account"}
             )

    conn = get(conn, ~p"/api/bootstrap")
    :ok = SessionSupervisor.stop_session(connection)
    payload = json_response(conn, 200)
    buffer_id = "direct:#{thread.id}"

    assert %{
             "buffer_id" => ^buffer_id,
             "buffer_type" => "direct_message",
             "direct_message_thread_id" => thread_id,
             "direct_message_revision" => direct_message_revision,
             "title" => "akash",
             "unread_count" => 1,
             "blocked" => false
           } = Enum.find(payload["buffers"], &(&1["buffer_id"] == buffer_id))

    assert thread_id == thread.id
    assert direct_message_revision == thread.mutation_revision

    assert [%{"id" => message_id, "body" => "hello privately"}] =
             payload["messages_by_buffer"][buffer_id]

    assert message_id == message.id

    scope = AccountsFixtures.user_scope_fixture(user)
    assert {:ok, closed} = Chat.close_direct_message_thread(scope, thread.id)

    closed_payload = conn |> recycle() |> get(~p"/api/bootstrap") |> json_response(200)
    refute Enum.any?(closed_payload["buffers"], &(&1["buffer_id"] == buffer_id))

    assert %{
             "buffer_id" => ^buffer_id,
             "server_connection_id" => server_connection_id,
             "direct_message_thread_id" => ^thread_id,
             "revision" => tombstone_revision
           } =
             Enum.find(
               closed_payload["direct_message_tombstones"],
               &(&1["buffer_id"] == buffer_id)
             )

    assert server_connection_id == connection.id
    assert tombstone_revision == closed.mutation_revision
    :ok = SessionSupervisor.stop_session(connection)
  end

  test "prefers a joined channel over an earlier pending channel", %{conn: conn, user: user} do
    server = start_supervised!({IrcTestServer, self()})

    {:ok, connection} =
      Connections.create(user, %{
        "name" => "local",
        "host" => "127.0.0.1",
        "port" => IrcTestServer.port(server),
        "use_tls" => false,
        "nickname" => "mira"
      })

    {:ok, pending} = Chat.request_channel_join(user, connection, "#pending")
    {:ok, joined} = Chat.join_channel(user, connection, "#joined")

    conn = get(conn, ~p"/api/bootstrap")

    assert %{"active_buffer_id" => active_buffer_id} = json_response(conn, 200)
    assert active_buffer_id == "channel:#{joined.id}"
    refute active_buffer_id == "channel:#{pending.id}"

    assert :ok = Session.quit(connection)
  end
end
