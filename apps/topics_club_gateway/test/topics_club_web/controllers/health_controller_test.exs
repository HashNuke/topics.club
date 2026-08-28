defmodule TopicsClubWeb.HealthControllerTest do
  use TopicsClubWeb.ConnCase, async: false

  test "reports readiness without authentication", %{conn: conn} do
    conn = get(conn, ~p"/health")

    assert %{
             "status" => "ok",
             "database" => "ok",
             "engine" => %{"mode" => "combined", "status" => "local"}
           } = json_response(conn, 200)
  end

  test "keeps persisted web readiness available while exposing a disconnected split engine", %{
    conn: conn
  } do
    previous_engine_node = Application.get_env(:topics_club_gateway, :engine_node)
    Application.put_env(:topics_club_gateway, :engine_node, :missing_engine@localhost)

    on_exit(fn ->
      if previous_engine_node do
        Application.put_env(:topics_club_gateway, :engine_node, previous_engine_node)
      else
        Application.delete_env(:topics_club_gateway, :engine_node)
      end
    end)

    conn = get(conn, ~p"/health")

    assert %{
             "status" => "degraded",
             "database" => "ok",
             "engine" => %{
               "mode" => "split",
               "status" => "disconnected",
               "node" => "missing_engine@localhost"
             }
           } = json_response(conn, 200)
  end

  test "production SSL policy permits a plain HTTP platform health check" do
    health_conn =
      :get
      |> build_conn("/health")
      |> Map.put(:host, "healthcheck.railway.app")
      |> Plug.SSL.call(Plug.SSL.init(production_ssl_options()))

    refute health_conn.halted
    assert health_conn.status == nil
    assert get_resp_header(health_conn, "location") == []

    browser_conn =
      :get
      |> build_conn("/")
      |> Map.put(:host, "topics-club.example.com")
      |> Plug.SSL.call(Plug.SSL.init(production_ssl_options()))

    assert browser_conn.halted
    assert browser_conn.status == 301
    assert get_resp_header(browser_conn, "location") == ["https://topics-club.example.com/"]
  end

  defp production_ssl_options do
    config_path = Path.expand("../../../../../config/prod.exs", __DIR__)

    config_path
    |> Config.Reader.read!(env: :prod)
    |> get_in([:topics_club_gateway, TopicsClubWeb.Endpoint, :force_ssl])
  end
end
