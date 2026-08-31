defmodule TopicsClubWeb.AppControllerTest do
  use TopicsClubWeb.ConnCase, async: true

  setup :register_and_log_in_user

  test "serves authenticated React deep links through the chat shell", %{conn: conn} do
    for path <- [
          "/chat/42",
          "/chat/42/%23elixir",
          "/chat/discover/all?p=2",
          "/chat/discover/42?p=3"
        ] do
      response = get(conn, path)
      assert html_response(response, 200) =~ ~s(id="topics-club-root")
    end
  end

  test "redirects unauthenticated deep links to login" do
    conn = get(build_conn(), "/chat/discover/all?p=2")

    assert redirected_to(conn) == ~p"/users/log-in"
  end
end
