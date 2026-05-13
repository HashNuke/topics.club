defmodule IrcpipeWeb.PageControllerTest do
  use IrcpipeWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    response = html_response(conn, 200)
    assert response =~ ~s(id="ircpipe-root")
    assert response =~ ~s(data-app-mode="landing")
  end
end
