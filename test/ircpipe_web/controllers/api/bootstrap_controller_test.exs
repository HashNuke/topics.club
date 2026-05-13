defmodule IrcpipeWeb.Api.BootstrapControllerTest do
  use IrcpipeWeb.ConnCase, async: true

  alias Ircpipe.AccountsFixtures
  alias Ircpipe.Chat
  alias Ircpipe.Chat.Topic
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
    {:ok, server_message} = Chat.record_server_message(connection, "Connected to local")
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
             "server_time" => _server_time,
             "connections" => [connection_json],
             "buffers" => [server_buffer, channel_buffer],
             "active_buffer_id" => active_buffer_id,
             "messages_by_buffer" => messages_by_buffer,
             "users_by_buffer" => users_by_buffer,
             "topics" => [topic_json]
           } = json_response(conn, 200)

    assert user_id == user.id
    assert connection_json["id"] == connection.id
    assert connection_json["channels"] == [membership.id]

    assert server_buffer["buffer_id"] == "server:#{connection.id}"
    assert server_buffer["buffer_type"] == "server"
    assert server_buffer["title"] == "127.0.0.1"

    assert channel_buffer["buffer_id"] == "channel:#{membership.id}"
    assert channel_buffer["buffer_type"] == "channel"
    assert channel_buffer["channel_membership_id"] == membership.id
    assert channel_buffer["title"] == "#elixir"
    assert channel_buffer["unread_count"] == 1

    channel_buffer_id = "channel:#{membership.id}"
    server_buffer_id = "server:#{connection.id}"

    assert active_buffer_id == channel_buffer_id

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

    assert topic_json["server_host"] == "127.0.0.1"
    refute Enum.any?(get_in(json_response(conn, 200), ["buffers"]), &(&1["title"] == "#private"))
  end
end
