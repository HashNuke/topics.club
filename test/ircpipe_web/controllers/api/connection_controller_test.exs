defmodule IrcpipeWeb.Api.ConnectionControllerTest do
  use IrcpipeWeb.ConnCase, async: false

  alias Ircpipe.Chat
  alias Ircpipe.Irc.Session
  alias Ircpipe.IrcTestServer

  setup :register_and_log_in_user

  test "creates and lists an owned server connection", %{conn: conn, user: user} do
    server = start_supervised!({IrcTestServer, self()})

    create_conn =
      post(conn, ~p"/api/connections", %{
        "connection" => %{
          "name" => "local",
          "host" => "127.0.0.1",
          "port" => IrcTestServer.port(server),
          "use_tls" => false,
          "nickname" => "mira"
        }
      })

    assert %{"connection" => %{"id" => connection_id, "host" => "127.0.0.1"}} =
             json_response(create_conn, 201)

    assert Chat.get_connection!(user, connection_id).nickname == "mira"

    list_conn = get(conn, ~p"/api/connections")

    assert %{"connections" => [%{"id" => ^connection_id, "host" => "127.0.0.1"}]} =
             json_response(list_conn, 200)

    connection = Chat.get_connection!(user, connection_id)
    assert_receive {:irc_server_line, "NICK mira"}, 1_000
    assert :ok = Session.quit(connection)
  end

  test "defaults an omitted nickname", %{conn: conn, user: user} do
    server = start_supervised!({IrcTestServer, self()})

    create_conn =
      post(conn, ~p"/api/connections", %{
        "connection" => %{
          "name" => "authenticated-local",
          "host" => "127.0.0.1",
          "port" => IrcTestServer.port(server),
          "use_tls" => false,
          "nickname" => ""
        }
      })

    expected_nickname = user.email |> String.split("@") |> List.first()

    assert %{"connection" => %{"id" => connection_id, "nickname" => ^expected_nickname}} =
             json_response(create_conn, 201)

    connection = Chat.get_connection!(user, connection_id)
    assert connection.nickname == expected_nickname
    assert_receive {:irc_server_line, "NICK " <> ^expected_nickname}, 1_000
    assert :ok = Session.quit(connection)
  end

  test "connects an owned server connection", %{conn: conn, user: user} do
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

    conn = post(conn, ~p"/api/connections/#{connection.id}/connect")

    assert %{"connection" => %{"id" => connection_id, "status" => "connecting"}} =
             json_response(conn, 200)

    assert connection_id == connection.id
    assert_receive {:irc_server_line, "NICK mira"}, 1_000
    assert :ok = Session.quit(connection)
  end

  test "reports live session status instead of stale database status", %{conn: conn, user: user} do
    server = start_supervised!({IrcTestServer, self()})

    {:ok, connection} =
      Chat.create_connection(user, %{
        "name" => "local",
        "host" => "127.0.0.1",
        "port" => IrcTestServer.port(server),
        "use_tls" => false,
        "nickname" => "mira",
        "status" => "connecting"
      })

    Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{user.id}")
    {:ok, _pid} = Ircpipe.Irc.SessionSupervisor.start_session(connection)

    assert_receive {:server_status, %{status: "connected"}}, 1_000
    assert Chat.get_connection!(user, connection.id).status == "connecting"

    list_conn = get(conn, ~p"/api/connections")

    assert %{"connections" => [%{"id" => connection_id, "status" => "connected"}]} =
             json_response(list_conn, 200)

    assert connection_id == connection.id
    assert :ok = Session.quit(connection)
  end

  test "disconnects an owned server connection", %{conn: conn, user: user} do
    {:ok, connection} =
      Chat.create_connection(user, %{
        "name" => "local",
        "host" => "127.0.0.1",
        "port" => 6667,
        "use_tls" => false,
        "nickname" => "mira",
        "status" => "connected"
      })

    conn = post(conn, ~p"/api/connections/#{connection.id}/disconnect")

    assert %{"connection" => %{"id" => connection_id, "status" => "disconnected"}} =
             json_response(conn, 200)

    assert connection_id == connection.id
    assert Session.status(connection) == "disconnected"
  end

  test "updates an owned server connection", %{conn: conn, user: user} do
    {:ok, connection} =
      Chat.create_connection(user, %{
        "name" => "local",
        "host" => "127.0.0.1",
        "port" => 6667,
        "use_tls" => false,
        "nickname" => "mira"
      })

    conn =
      put(conn, ~p"/api/connections/#{connection.id}", %{
        "connection" => %{
          "name" => "local-edited",
          "host" => "localhost",
          "port" => 6697,
          "use_tls" => true,
          "nickname" => "mira2",
          "casemapping" => "rfc1459"
        }
      })

    assert %{
             "connection" => %{
               "id" => connection_id,
               "name" => "local-edited",
               "host" => "localhost",
               "port" => 6697,
               "use_tls" => true,
               "nickname" => "mira2"
             }
           } = json_response(conn, 200)

    assert connection_id == connection.id
    assert Chat.get_connection!(user, connection.id).casemapping == nil
  end

  test "deletes an owned server connection", %{conn: conn, user: user} do
    {:ok, connection} =
      Chat.create_connection(user, %{
        "name" => "local",
        "host" => "127.0.0.1",
        "port" => 6667,
        "use_tls" => false,
        "nickname" => "mira"
      })

    {:ok, membership} = Chat.join_channel(user, connection, "#elixir")
    Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{user.id}")

    conn = delete(conn, ~p"/api/connections/#{connection.id}")

    assert %{
             "deleted" => %{
               "type" => "server:deleted",
               "version" => 1,
               "event_id" => "server_deleted:" <> _,
               "occurred_at" => _occurred_at,
               "server_connection_id" => connection_id
             }
           } =
             json_response(conn, 200)

    assert connection_id == connection.id

    assert_receive {:buffer_left,
                    %{
                      type: "buffer:left",
                      buffer_id: channel_buffer_id,
                      server_connection_id: ^connection_id,
                      channel_membership_id: channel_membership_id
                    }}

    assert channel_buffer_id == "channel:#{membership.id}"
    assert channel_membership_id == membership.id

    assert_receive {:buffer_left,
                    %{
                      type: "buffer:left",
                      buffer_id: server_buffer_id,
                      server_connection_id: ^connection_id,
                      channel_membership_id: nil
                    }}

    assert server_buffer_id == "server:#{connection.id}"
    assert_raise Ecto.NoResultsError, fn -> Chat.get_connection!(user, connection.id) end
  end

  test "does not disconnect another user's server connection", %{conn: conn} do
    other_user = Ircpipe.AccountsFixtures.user_fixture()

    {:ok, connection} =
      Chat.create_connection(other_user, %{
        "name" => "other",
        "host" => "127.0.0.1",
        "port" => 6667,
        "use_tls" => false,
        "nickname" => "other"
      })

    assert_error_sent 404, fn ->
      post(conn, ~p"/api/connections/#{connection.id}/disconnect")
    end
  end
end
