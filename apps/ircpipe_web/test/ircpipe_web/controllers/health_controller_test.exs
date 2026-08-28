defmodule IrcpipeWeb.HealthControllerTest do
  use IrcpipeWeb.ConnCase, async: true

  test "reports readiness without authentication", %{conn: conn} do
    conn = get(conn, ~p"/health")

    assert %{"status" => "ok"} = json_response(conn, 200)
  end
end
