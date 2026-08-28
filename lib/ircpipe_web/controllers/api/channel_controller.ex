defmodule IrcpipeWeb.Api.ChannelController do
  use IrcpipeWeb, :controller

  alias Ircpipe.Chat.{Connections, MembershipLookup}
  alias Ircpipe.EngineClient
  alias Ircpipe.Irc.CommandRegistry

  def create(conn, %{"connection_id" => connection_id, "channel" => channel}) do
    user = conn.assigns.current_scope.user
    connection = Connections.get!(user, connection_id)

    with :ok <- CommandRegistry.validate_join_channel_syntax(channel),
         {:ok, %{membership: membership, status: status}} <-
           EngineClient.join_channel(user.id, connection.id, channel) do
      conn
      |> maybe_accept_queued(status)
      |> json(%{channel: channel_json(membership), status: status})
    else
      {:error, %{code: code}} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: code})

      {:error, reason} ->
        conn
        |> put_status(join_status(reason))
        |> json(%{error: join_error(reason)})
    end
  end

  def leave(conn, %{"id" => id}) do
    user = conn.assigns.current_scope.user
    membership = MembershipLookup.get!(user, id)

    case EngineClient.part_channel(user.id, membership.server_connection_id, membership.id) do
      {:ok, %{status: status}} ->
        json(conn, %{
          status: status,
          buffer_id: "channel:#{membership.id}"
        })

      {:error, %{code: code}} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: code})
    end
  end

  defp channel_json(channel) do
    %{
      id: channel.id,
      connection_id: channel.server_connection_id,
      channel: channel.channel,
      unread_count: channel.unread_count,
      mention_count: channel.mention_count,
      mention_notifications_enabled: channel.mention_notifications_enabled,
      notification_preference_revision: channel.notification_preference_revision
    }
  end

  defp maybe_accept_queued(conn, "queued"), do: put_status(conn, :accepted)
  defp maybe_accept_queued(conn, "sent"), do: conn

  defp join_status(:not_connected), do: :service_unavailable

  defp join_status(%{code: code}) when code in [:engine_unavailable, :not_connected, :timeout],
    do: :service_unavailable

  defp join_status(_reason), do: :unprocessable_entity

  defp join_error(%{code: code}), do: code
  defp join_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp join_error(reason), do: inspect(reason)
end
