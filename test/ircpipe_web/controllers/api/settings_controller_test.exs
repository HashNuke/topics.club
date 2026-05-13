defmodule IrcpipeWeb.Api.SettingsControllerTest do
  use IrcpipeWeb.ConnCase, async: true

  setup :register_and_log_in_user

  test "updates message retention days for the current user", %{conn: conn} do
    conn = put(conn, ~p"/api/settings", %{"message_retention_days" => "2"})

    assert %{"user" => %{"message_retention_days" => 2}} = json_response(conn, 200)
  end

  test "clamps message retention days to the supported range", %{conn: conn} do
    conn = put(conn, ~p"/api/settings", %{"message_retention_days" => "9"})

    assert %{"user" => %{"message_retention_days" => 3}} = json_response(conn, 200)
  end
end
