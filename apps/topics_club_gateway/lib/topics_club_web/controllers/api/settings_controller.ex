defmodule TopicsClubWeb.Api.SettingsController do
  use TopicsClubWeb, :controller

  alias TopicsClub.Chat.Retention

  def update(conn, %{"message_retention_days" => days}) do
    user = conn.assigns.current_scope.user
    {:ok, user} = Retention.update_days(user, days)

    json(conn, %{
      user: %{id: user.id, email: user.email, message_retention_days: user.message_retention_days}
    })
  end
end
