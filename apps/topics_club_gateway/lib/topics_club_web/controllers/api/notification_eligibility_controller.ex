defmodule TopicsClubWeb.Api.NotificationEligibilityController do
  use TopicsClubWeb, :controller

  alias TopicsClub.Notifications.Delivery

  def show(conn, %{"id" => id, "session_generation" => session_generation}) do
    if conn.assigns.current_scope do
      conn
      |> put_resp_header("cache-control", "no-store")
      |> json(%{
        eligible:
          Delivery.eligible?(
            conn.assigns.current_scope,
            conn.assigns.notification_session_token,
            id,
            session_generation
          )
      })
    else
      unauthorized(conn)
    end
  end

  def show(conn, _params) do
    if conn.assigns.current_scope do
      conn
      |> put_resp_header("cache-control", "no-store")
      |> json(%{eligible: false})
    else
      unauthorized(conn)
    end
  end

  defp unauthorized(conn) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_status(:unauthorized)
    |> json(%{error: "authentication_required"})
  end
end
