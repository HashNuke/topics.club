defmodule TopicsClubWeb.HealthController do
  use TopicsClubWeb, :controller

  def show(conn, _params) do
    case Ecto.Adapters.SQL.query(TopicsClub.Repo, "SELECT 1", [], timeout: 1_000) do
      {:ok, _result} -> json(conn, health_payload())
      {:error, _reason} -> unavailable(conn)
    end
  rescue
    _exception -> unavailable(conn)
  catch
    :exit, _reason -> unavailable(conn)
  end

  defp health_payload do
    case Application.get_env(:topics_club_gateway, :engine_node) do
      nil ->
        %{status: "ok", database: "ok", engine: %{mode: "combined", status: "local"}}

      engine_node ->
        engine = split_engine_health(engine_node)
        status = if engine.status == "connected", do: "ok", else: "degraded"
        %{status: status, database: "ok", engine: engine}
    end
  end

  defp split_engine_health(engine_node) do
    connector_status = TopicsClubWeb.EngineNodeConnector.status()

    %{
      mode: "split",
      node: Atom.to_string(engine_node),
      status: if(connector_status.connected?, do: "connected", else: "disconnected"),
      retry_attempt: connector_status.retry_attempt
    }
  catch
    :exit, _reason ->
      %{
        mode: "split",
        node: Atom.to_string(engine_node),
        status: "disconnected",
        retry_attempt: 0
      }
  end

  defp unavailable(conn) do
    conn
    |> put_status(:service_unavailable)
    |> json(%{status: "unavailable"})
  end
end
