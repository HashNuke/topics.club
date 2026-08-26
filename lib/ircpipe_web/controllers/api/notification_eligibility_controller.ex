defmodule IrcpipeWeb.Api.NotificationEligibilityController do
  use IrcpipeWeb, :controller

  alias Ircpipe.Notifications.Delivery

  def show(conn, %{"id" => id, "session_generation" => session_generation}) do
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
  end

  def show(conn, _params) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> json(%{eligible: false})
  end
end
