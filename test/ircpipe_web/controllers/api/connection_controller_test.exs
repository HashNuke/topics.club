defmodule IrcpipeWeb.Api.ConnectionControllerTest do
  use IrcpipeWeb.ConnCase, async: true

  alias Ircpipe.Chat

  setup :register_and_log_in_user

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
    assert Chat.get_connection!(user, connection.id).status == "disconnected"
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
