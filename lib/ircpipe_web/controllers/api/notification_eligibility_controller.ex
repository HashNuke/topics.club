defmodule IrcpipeWeb.Api.NotificationEligibilityController do
  use IrcpipeWeb, :controller

  alias Ircpipe.Notifications

  def show(conn, %{"id" => id, "session_generation" => session_generation}) do
    json(conn, %{
      eligible:
        Notifications.notification_eligible?(
          conn.assigns.current_scope,
          conn.assigns.notification_session_token,
          id,
          session_generation
        )
    })
  end

  def show(conn, _params), do: json(conn, %{eligible: false})
end
