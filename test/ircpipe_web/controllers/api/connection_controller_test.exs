defmodule IrcpipeWeb.Api.ConnectionControllerTest do
  use IrcpipeWeb.ConnCase, async: false

  alias Ircpipe.Chat
  alias Ircpipe.Chat.Connections
  alias Ircpipe.Irc.Session
  alias Ircpipe.Irc.SessionLocator
  alias Ircpipe.IrcTestServer

  setup :register_and_log_in_user

  test "returns a degraded response when connection operations cannot reach the engine", %{
    user: user
  } do
    {:ok, connection} =
      Connections.create(user, %{
        "name" => "degraded",
        "host" => "127.0.0.1",
        "port" => 6667,
        "use_tls" => false,
        "nickname" => "mira"
      })

    configure_engine_test_adapter()

    for code <- [:engine_unavailable, :timeout] do
      Application.put_env(:ircpipe, :engine_client_test_reply, {:error, code})

      for path <- [
            ~p"/api/connections/#{connection.id}/connect",
            ~p"/api/connections/#{connection.id}/disconnect"
          ] do
        response = build_conn() |> log_in_user(user) |> post(path)
        assert %{"error" => error} = json_response(response, 503)
        assert error == Atom.to_string(code)
      end

      response =
        build_conn()
        |> log_in_user(user)
        |> post(~p"/api/connections", %{
          "connection" => %{
            "name" => "degraded",
            "host" => "127.0.0.1",
            "port" => 6667,
            "use_tls" => false,
            "nickname" => "mira"
          }
        })

      assert %{"error" => error} = json_response(response, 503)
      assert error == Atom.to_string(code)

      delete_response =
        build_conn()
        |> log_in_user(user)
        |> delete(~p"/api/connections/#{connection.id}")

      assert %{"error" => delete_error} = json_response(delete_response, 503)
      assert delete_error == Atom.to_string(code)
    end
  end

  test "returns connection validation errors as an HTTP response", %{conn: conn} do
    response =
      post(conn, ~p"/api/connections", %{
        "connection" => %{
          "name" => "",
          "host" => "",
          "nickname" => ""
        }
      })

    assert %{
             "error" => "invalid_connection",
             "errors" => %{"host" => [_], "name" => [_]}
           } = json_response(response, 422)
  end

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

    assert Connections.get!(user, connection_id).nickname == "mira"

    list_conn = get(conn, ~p"/api/connections")

    assert %{"connections" => [%{"id" => ^connection_id, "host" => "127.0.0.1"}]} =
             json_response(list_conn, 200)

    connection = Connections.get!(user, connection_id)
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

    connection = Connections.get!(user, connection_id)
    assert connection.nickname == expected_nickname
    assert_receive {:irc_server_line, "NICK " <> ^expected_nickname}, 1_000
    assert :ok = Session.quit(connection)
  end

  test "connects an owned server connection", %{conn: conn, user: user} do
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

    conn = post(conn, ~p"/api/connections/#{connection.id}/connect")

    assert %{"connection" => %{"id" => connection_id, "status" => "connecting"}} =
             json_response(conn, 200)

    assert connection_id == connection.id
    assert_receive {:irc_server_line, "NICK mira"}, 1_000
    assert Connections.get!(user, connection.id).desired_state == "connected"
    assert :ok = Session.quit(connection)
  end

  test "reports live session status instead of stale database status", %{conn: conn, user: user} do
    server = start_supervised!({IrcTestServer, self()})

    {:ok, connection} =
      Connections.create(user, %{
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
    assert Connections.get!(user, connection.id).status == "connecting"

    list_conn = get(conn, ~p"/api/connections")

    assert %{"connections" => [%{"id" => connection_id, "status" => "connected"}]} =
             json_response(list_conn, 200)

    assert connection_id == connection.id
    assert :ok = Session.quit(connection)
  end

  test "disconnects an owned server connection", %{conn: conn, user: user} do
    {:ok, connection} =
      Connections.create(user, %{
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
    assert SessionLocator.status(connection) == "disconnected"
    assert Connections.get!(user, connection.id).desired_state == "paused"
  end

  test "updates an owned server connection", %{conn: conn, user: user} do
    {:ok, connection} =
      Connections.create(user, %{
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
    assert Connections.get!(user, connection.id).casemapping == nil
  end

  test "deletes an owned server connection", %{conn: conn, user: user} do
    {:ok, connection} =
      Connections.create(user, %{
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
    assert_raise Ecto.NoResultsError, fn -> Connections.get!(user, connection.id) end
  end

  test "does not disconnect another user's server connection", %{conn: conn} do
    other_user = Ircpipe.AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(other_user, %{
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

  defp configure_engine_test_adapter do
    previous_adapter = Application.get_env(:ircpipe, :engine_client_adapter)
    previous_test_pid = Application.get_env(:ircpipe, :engine_client_test_pid)
    previous_test_reply = Application.get_env(:ircpipe, :engine_client_test_reply)

    Application.put_env(:ircpipe, :engine_client_adapter, Ircpipe.EngineClientTestAdapter)
    Application.put_env(:ircpipe, :engine_client_test_pid, self())

    on_exit(fn ->
      restore_env(:engine_client_adapter, previous_adapter)
      restore_env(:engine_client_test_pid, previous_test_pid)
      restore_env(:engine_client_test_reply, previous_test_reply)
    end)
  end

  defp restore_env(key, nil), do: Application.delete_env(:ircpipe, key)
  defp restore_env(key, value), do: Application.put_env(:ircpipe, key, value)
end
