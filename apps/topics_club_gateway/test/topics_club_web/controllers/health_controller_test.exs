defmodule TopicsClubWeb.HealthControllerTest do
  use TopicsClubWeb.ConnCase, async: false

  alias TopicsClub.EngineClient.RpcAdapter
  alias TopicsClubWeb.EngineNodeConnector

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

  test "does not report a transport-only connection as engine readiness", %{conn: conn} do
    started_distribution? = start_distribution()
    on_exit(fn -> if started_distribution?, do: :net_kernel.stop() end)

    peer_name = :health_transport_only_peer

    peer_pid =
      start_supervised!(%{
        id: peer_name,
        start:
          {:peer, :start_link, [%{name: peer_name, connection: :standard_io, shutdown: 5_000}]},
        restart: :temporary,
        shutdown: 10_000
      })

    peer_node = :peer.call(peer_pid, :erlang, :node, [])
    assert Node.connect(peer_node)

    start_supervised!({EngineNodeConnector, engine_node: peer_node, retry_min: 10, retry_max: 10})

    _ = :sys.get_state(EngineNodeConnector)
    assert EngineNodeConnector.status().connected?

    previous = configure_split_runtime(peer_node)
    on_exit(fn -> restore_split_runtime(previous) end)

    conn = get(conn, ~p"/health")

    assert %{
             "status" => "degraded",
             "database" => "ok",
             "engine" => %{
               "mode" => "split",
               "status" => "unavailable",
               "node" => engine_node
             }
           } = json_response(conn, 200)

    assert engine_node == Atom.to_string(peer_node)
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

  defp start_distribution do
    if Node.alive?() do
      false
    else
      assert {:ok, _pid} = :net_kernel.start([:health_gateway_test, :shortnames])
      true
    end
  end

  defp configure_split_runtime(engine_node) do
    previous = %{
      adapter: Application.get_env(:topics_club_core, :engine_client_adapter),
      engine_node: Application.get_env(:topics_club_gateway, :engine_node)
    }

    Application.put_env(:topics_club_core, :engine_client_adapter, RpcAdapter)
    Application.put_env(:topics_club_gateway, :engine_node, engine_node)
    previous
  end

  defp restore_split_runtime(previous) do
    restore_env(:topics_club_core, :engine_client_adapter, previous.adapter)
    restore_env(:topics_club_gateway, :engine_node, previous.engine_node)
  end

  defp restore_env(application, key, nil), do: Application.delete_env(application, key)
  defp restore_env(application, key, value), do: Application.put_env(application, key, value)
end
