defmodule IrcpipeWeb.PageControllerTest do
  use IrcpipeWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    response = html_response(conn, 200)
    assert response =~ ~s(id="ircpipe-root")
    assert response =~ ~s(data-app-mode="landing")
  end

  test "the PWA manifest starts at the canonical chat route", %{conn: conn} do
    conn = get(conn, "/manifest.webmanifest")

    assert %{"id" => "/chat", "start_url" => "/chat"} =
             conn
             |> response(200)
             |> Jason.decode!()
  end
end
