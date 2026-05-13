defmodule IrcpipeWeb.Api.SettingsController do
  use IrcpipeWeb, :controller

  alias Ircpipe.Chat

  def update(conn, %{"message_retention_days" => days}) do
    user = conn.assigns.current_scope.user
    {:ok, user} = Chat.update_retention_days(user, days)

    json(conn, %{
      user: %{id: user.id, email: user.email, message_retention_days: user.message_retention_days}
    })
  end
end
