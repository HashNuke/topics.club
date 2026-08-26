defmodule IrcpipeWeb.Api.BootstrapControllerTest do
  use IrcpipeWeb.ConnCase, async: false

  alias Ircpipe.AccountsFixtures
  alias Ircpipe.Chat
  alias Ircpipe.Chat.Topic
  alias Ircpipe.Irc.Session
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
      Chat.create_connection(user, %{
        "name" => "local",
        "host" => "127.0.0.1",
        "port" => 6667,
        "use_tls" => false,
        "nickname" => "mira",
        "status" => "connected"
      })

    {:ok, membership} = Chat.join_channel(user, connection, "#elixir")
    {:ok, archived_membership} = Chat.join_channel(user, connection, "#archive")
    Chat.record_inbound_message(connection, "#archive", "akash", "retained archive")
    {:ok, _archived_membership} = Chat.confirm_channel_left(connection, "#archive")
    {:ok, server_message} = Chat.record_server_message(connection, "Connected to local")

    {:ok, channel_message} =
      Chat.record_inbound_message(connection, "#elixir", "akash", "hello mira")

    Chat.broadcast_presence_sync(connection, "#elixir", [
      %{nick: "mira", prefixes: ["@"], raw_source: "mira!user@example.test"},
      %{nick: "akash", prefixes: []}
    ])

    {:ok, other_connection} =
      Chat.create_connection(other_user, %{
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

    conn = get(conn, ~p"/api/bootstrap")

    assert %{
             "user" => %{"id" => user_id, "email" => _email, "message_retention_days" => 3},
             "notification_state" => "default",
             "command_catalog" => command_catalog,
             "server_time" => _server_time,
             "connections" => [connection_json],
             "buffers" => [server_buffer, channel_buffer],
             "active_buffer_id" => active_buffer_id,
             "messages_by_buffer" => messages_by_buffer,
             "message_cursors_by_buffer" => message_cursors_by_buffer,
             "users_by_buffer" => users_by_buffer,
             "topics" => topics_json
           } = json_response(conn, 200)

    assert user_id == user.id
    assert connection_json["id"] == connection.id
    assert connection_json["channels"] == [membership.id]
    assert Enum.any?(command_catalog, &(&1["name"] == "/quote"))

    assert server_buffer["buffer_id"] == "server:#{connection.id}"
    assert server_buffer["buffer_type"] == "server"
    assert server_buffer["title"] == "127.0.0.1"
    assert server_buffer["unread_count"] == 1

    assert channel_buffer["buffer_id"] == "channel:#{membership.id}"
    assert channel_buffer["buffer_type"] == "channel"
    assert channel_buffer["channel_membership_id"] == membership.id
    assert channel_buffer["title"] == "#elixir"
    assert channel_buffer["unread_count"] == 1

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
  end

  test "starts persisted IRC sessions and rejoins channels on bootstrap", %{
    conn: conn,
    user: user
  } do
    server = start_supervised!({IrcTestServer, self()})

    {:ok, connection} =
      Chat.create_connection(user, %{
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

  test "prefers a joined channel over an earlier pending channel", %{conn: conn, user: user} do
    server = start_supervised!({IrcTestServer, self()})

    {:ok, connection} =
      Chat.create_connection(user, %{
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
