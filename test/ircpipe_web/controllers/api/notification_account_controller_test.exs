defmodule IrcpipeWeb.Api.NotificationAccountControllerTest do
  use IrcpipeWeb.ConnCase, async: true

  import Ecto.Query

  alias Ircpipe.Accounts.UserToken
  alias Ircpipe.Repo

  setup :register_and_log_in_user

  test "returns the current server-authenticated notification account", %{conn: conn, user: user} do
    token = get_session(conn, :user_token)
    conn = get(conn, ~p"/api/notification-account")

    assert %{
             "user_id" => user_id,
             "session_generation" => session_generation
           } = json_response(conn, 200)

    assert user_id == user.id
    assert session_generation == UserToken.session_token_fingerprint(token)
  end

  test "returns an empty account without an authenticated session" do
    conn = build_conn() |> get(~p"/api/notification-account")

    assert %{"user_id" => nil, "session_generation" => nil} = json_response(conn, 200)
  end

  test "does not rotate an aging session while checking notification ownership", %{conn: conn} do
    token = get_session(conn, :user_token)
    aging_at = DateTime.utc_now(:second) |> DateTime.add(-10, :day)

    UserToken
    |> where([user_token], user_token.token == ^token and user_token.context == "session")
    |> Repo.update_all(set: [inserted_at: aging_at])

    checked = get(conn, ~p"/api/notification-account")

    assert get_session(checked, :user_token) == token

    assert json_response(checked, 200)["session_generation"] ==
             UserToken.session_token_fingerprint(token)
  end
end
