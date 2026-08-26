defmodule IrcpipeWeb.Api.NotificationAccountController do
  use IrcpipeWeb, :controller

  alias Ircpipe.Notifications

  def show(conn, _params) do
    json(
      conn,
      Notifications.notification_account(
        conn.assigns.current_scope,
        get_session(conn, :user_token)
      )
    )
  end
end
