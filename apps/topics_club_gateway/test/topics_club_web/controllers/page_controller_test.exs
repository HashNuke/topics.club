defmodule TopicsClubWeb.PageControllerTest do
  use TopicsClubWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    response = html_response(conn, 200)
    assert response =~ ~s(id="topics-club-root")
    assert response =~ ~s(data-app-mode="landing")
    assert response =~ ~s(data-featured-channels="[]")
  end

  test "the JSON route scopes reject requests without a session", %{conn: conn} do
    for path <- [
          "/api/topics",
          "/api/bootstrap",
          "/api/discovery/server_channels",
          "/api/connections"
        ] do
      response = get(recycle(conn), path)
      assert redirected_to(response) == ~p"/users/log-in"
    end

    account = get(recycle(conn), "/api/notification-account")
    assert json_response(account, 401)["error"] == "authentication_required"

    eligibility =
      get(recycle(conn), "/api/notifications/1/eligibility?session_generation=unknown")

    assert json_response(eligibility, 401)["error"] == "authentication_required"

    removed_public_api = get(recycle(conn), "/api/discovery/featured_channels")
    assert response(removed_public_api, 404)
  end

  test "the PWA manifest starts at the canonical chat route", %{conn: conn} do
    conn = get(conn, "/manifest.webmanifest")

    assert %{"id" => "/chat", "start_url" => "/chat"} =
             conn
             |> response(200)
             |> Jason.decode!()
  end
end
