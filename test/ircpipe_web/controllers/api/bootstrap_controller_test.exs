defmodule IrcpipeWeb.Api.BootstrapControllerTest do
  use IrcpipeWeb.ConnCase, async: false

  alias Ircpipe.AccountsFixtures
  alias Ircpipe.Chat
  alias Ircpipe.Chat.ChannelJoinRequest
  alias Ircpipe.Chat.ChannelPartLifecycle
  alias Ircpipe.Chat.Presence
  alias Ircpipe.Chat.Connections
  alias Ircpipe.Chat.DirectMessageIngestion
  alias Ircpipe.Chat.DirectMessageLifecycle
  alias Ircpipe.Chat.MessageIngestion
  alias Ircpipe.Chat.Topic
  alias Ircpipe.Irc.{Session, SessionLocator, SessionSupervisor}
  alias Ircpipe.IrcTestServer
  alias Ircpipe.Repo
  alias IrcpipeWeb.EngineRestorer

  setup :register_and_log_in_user

  setup %{user: user} do
    previous_adapter = Application.get_env(:ircpipe, :engine_client_adapter)
    previous_test_pid = Application.get_env(:ircpipe, :engine_client_test_pid)
    previous_test_reply = Application.get_env(:ircpipe, :engine_client_test_reply)

    Application.put_env(:ircpipe, :engine_client_adapter, Ircpipe.EngineClientTestAdapter)
    Application.put_env(:ircpipe, :engine_client_test_pid, self())
    Application.put_env(:ircpipe, :engine_client_test_reply, {:error, :engine_unavailable})

    on_exit(fn ->
      :ok = EngineRestorer.await_idle()
      Enum.each(Connections.list(user), &SessionSupervisor.stop_session/1)
      restore_env(:engine_client_adapter, previous_adapter)
      restore_env(:engine_client_test_pid, previous_test_pid)
      restore_env(:engine_client_test_reply, previous_test_reply)
    end)

    :ok
  end

  test "requires authentication" do
    conn = build_conn() |> get(~p"/api/bootstrap")

    assert redirected_to(conn) == ~p"/users/log-in"
  end

  test "does not restore a paused server connection", %{conn: conn, user: user} do
    server = start_supervised!({IrcTestServer, self()})

    assert {:ok, connection} =
             Connections.create(user, %{
               "name" => "paused",
               "host" => "127.0.0.1",
               "port" => IrcTestServer.port(server),
               "use_tls" => false,
               "nickname" => "mira"
             })

    assert {:ok, _paused} =
             connection
             |> Ecto.Changeset.change(desired_state: "paused")
             |> Repo.update()

    assert %{"connections" => [%{"status" => "disconnected"}]} =
             conn |> get(~p"/api/bootstrap") |> json_response(200)

    assert Repo.get!(Ircpipe.Chat.ServerConnection, connection.id).desired_state == "paused"
    assert SessionLocator.status(connection) == "disconnected"
    refute_receive {:irc_server_line, "NICK mira"}
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
    {:ok, direct_message_thread} = DirectMessageLifecycle.open(user, connection, "Zed")
    {:ok, archived_membership} = Chat.join_channel(user, connection, "#archive")
    MessageIngestion.record_channel(connection, "#archive", "akash", "retained archive")
    {:ok, _archived_membership} = ChannelPartLifecycle.confirm(connection, "#archive")
    {:ok, server_message} = MessageIngestion.record_server(connection, "Connected to local")

    {:ok, channel_message} =
      MessageIngestion.record_channel(connection, "#elixir", "akash", "hello mira")

    Presence.sync(
      connection,
      "#elixir",
      [
        %{nick: "mira", prefixes: ["@"], raw_source: "mira!user@example.test"},
        %{nick: "akash", prefixes: []}
      ],
      :rfc1459
    )

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
    payload = json_response(conn, 200)

    assert Enum.sort(Map.keys(payload)) ==
             Enum.sort(~w(
               active_buffer_id
               buffers
               command_catalog
               connections
               direct_message_tombstones
               message_cursors_by_buffer
               messages_by_buffer
               push
               server_time
               topics
               user
               users_by_buffer
             ))

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
           } = payload

    assert user_id == user.id
    assert is_binary(session_generation)
    assert connection_json["id"] == connection.id
    refute Map.has_key?(connection_json, "channels")
    refute Map.has_key?(connection_json, "direct_messages")
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
    Application.put_env(:ircpipe, :engine_client_adapter, Ircpipe.Engine.LocalAdapter)
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
             DirectMessageIngestion.record(
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

    assert {:ok, closed} =
             DirectMessageLifecycle.close(scope, thread.id, thread.mutation_revision)

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

    {:ok, pending} = ChannelJoinRequest.request(user, connection, "#pending")
    {:ok, joined} = Chat.join_channel(user, connection, "#joined")

    conn = get(conn, ~p"/api/bootstrap")

    assert %{"active_buffer_id" => active_buffer_id} = json_response(conn, 200)
    assert active_buffer_id == "channel:#{joined.id}"
    refute active_buffer_id == "channel:#{pending.id}"
  end

  defp restore_env(key, nil), do: Application.delete_env(:ircpipe, key)
  defp restore_env(key, value), do: Application.put_env(:ircpipe, key, value)
end
