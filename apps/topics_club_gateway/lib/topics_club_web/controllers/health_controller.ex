defmodule TopicsClubWeb.HealthController do
  use TopicsClubWeb, :controller

  def show(conn, _params) do
    case Ecto.Adapters.SQL.query(TopicsClub.Repo, "SELECT 1", [], timeout: 1_000) do
      {:ok, _result} -> json(conn, %{status: "ok"})
      {:error, _reason} -> unavailable(conn)
    end
  rescue
    _exception -> unavailable(conn)
  catch
    :exit, _reason -> unavailable(conn)
  end

  defp unavailable(conn) do
    conn
    |> put_status(:service_unavailable)
    |> json(%{status: "unavailable"})
  end
end
