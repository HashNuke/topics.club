defmodule IrcpipeWeb.Api.NotificationAccountController do
  use IrcpipeWeb, :controller

  alias Ircpipe.Notifications.SessionBindings

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
