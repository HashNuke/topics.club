defmodule IrcpipeWeb.Api.NotificationPreferenceController do
  use IrcpipeWeb, :controller

  alias Ircpipe.Notifications

  def update_server(conn, %{"id" => id, "mention_notifications_enabled" => enabled})
      when is_boolean(enabled) do
    case Notifications.update_server_preference(conn.assigns.current_scope, id, enabled) do
      {:ok, connection} ->
        json(conn, %{
          preference: %{
            scope: "server",
            id: connection.id,
            mention_notifications_enabled: connection.mention_notifications_enabled,
            revision: connection.notification_preference_revision
          }
        })

      {:error, _changeset} ->
        invalid_preference(conn)
    end
  rescue
    Ecto.NoResultsError -> not_found(conn)
    Ecto.Query.CastError -> not_found(conn)
  end

  def update_server(conn, _params), do: invalid_preference(conn)

  def update_channel(conn, %{"id" => id, "mention_notifications_enabled" => enabled})
      when is_boolean(enabled) do
    case Notifications.update_channel_preference(conn.assigns.current_scope, id, enabled) do
      {:ok, membership} ->
        json(conn, %{
          preference: %{
            scope: "channel",
            id: membership.id,
            mention_notifications_enabled: membership.mention_notifications_enabled,
            revision: membership.notification_preference_revision
          }
        })

      {:error, _changeset} ->
        invalid_preference(conn)
    end
  rescue
    Ecto.NoResultsError -> not_found(conn)
    Ecto.Query.CastError -> not_found(conn)
  end

  def update_channel(conn, _params), do: invalid_preference(conn)

  defp invalid_preference(conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "invalid_notification_preference"})
  end

  defp not_found(conn) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "notification_scope_not_found"})
  end
end
