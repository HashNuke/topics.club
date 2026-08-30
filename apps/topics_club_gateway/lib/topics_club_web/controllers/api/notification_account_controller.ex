defmodule TopicsClubWeb.Api.NotificationAccountController do
  use TopicsClubWeb, :controller

  alias TopicsClub.Notifications.SessionBindings

  def show(conn, _params) do
    account =
      SessionBindings.notification_account(
        conn.assigns.current_scope,
        conn.assigns.notification_session_token
      )

    if account.user_id do
      json(conn, account)
    else
      conn
      |> put_status(:unauthorized)
      |> json(%{error: "authentication_required"})
    end
  end
end
