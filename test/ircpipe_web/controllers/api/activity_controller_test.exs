defmodule IrcpipeWeb.Api.ActivityControllerTest do
  use IrcpipeWeb.ConnCase, async: true

  alias Ircpipe.Accounts

  setup :register_and_log_in_user

  test "records authenticated browser activity", %{conn: conn, user: user} do
    refute Accounts.get_user!(user.id).last_seen_at

    conn = post(conn, ~p"/api/activity", %{})

    assert %{"ok" => true, "server_time" => _server_time} = json_response(conn, 200)
    assert Accounts.get_user!(user.id).last_seen_at
  end

  test "requires authentication" do
    conn = build_conn() |> post(~p"/api/activity", %{})

    assert redirected_to(conn) == ~p"/users/log-in"
  end
end
