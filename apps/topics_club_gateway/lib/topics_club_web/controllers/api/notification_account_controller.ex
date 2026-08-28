defmodule TopicsClubWeb.Api.NotificationAccountController do
  use TopicsClubWeb, :controller

  alias TopicsClub.Notifications.SessionBindings

  def show(conn, _params) do
    json(
      conn,
      SessionBindings.notification_account(
        conn.assigns.current_scope,
        conn.assigns.notification_session_token
      )
    )
  end
end
