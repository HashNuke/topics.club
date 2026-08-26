defmodule IrcpipeWeb.Api.ChannelController do
  use IrcpipeWeb, :controller

  alias Ircpipe.Chat
  alias Ircpipe.Chat.Connections
  alias Ircpipe.Irc.CommandRegistry
  alias Ircpipe.Irc.Session
  alias Ircpipe.Irc.SessionSupervisor

  def create(conn, %{"connection_id" => connection_id, "channel" => channel}) do
    user = conn.assigns.current_scope.user
    connection = Connections.get!(user, connection_id)

    with :ok <- CommandRegistry.validate_join_channel_syntax(channel),
         :ok <- start_session(connection),
         {:ok, membership, status} <- try_join(connection, user, channel) do
      conn
      |> maybe_accept_queued(status)
      |> json(%{channel: channel_json(membership), status: Atom.to_string(status)})
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

  def mark_read(conn, %{"id" => id}) do
    user = conn.assigns.current_scope.user
    membership = Chat.get_membership!(user, id)
    :ok = Chat.mark_read(user, membership)
    json(conn, %{ok: true})
  end

  def leave(conn, %{"id" => id}) do
    user = conn.assigns.current_scope.user
    membership = Chat.get_membership!(user, id)

    case try_part(membership) do
      :ok ->
        json(conn, %{
          status: "sent",
          buffer_id: "channel:#{membership.id}"
        })

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: to_string(reason)})
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

  defp try_join(connection, user, channel) do
    Session.request_join(connection, user, channel)
  catch
    :exit, _ -> {:error, :not_connected}
  end

  defp maybe_accept_queued(conn, :queued), do: put_status(conn, :accepted)
  defp maybe_accept_queued(conn, :sent), do: conn

  defp join_status(:not_connected), do: :service_unavailable
  defp join_status(_reason), do: :unprocessable_entity

  defp join_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp join_error(reason), do: inspect(reason)

  defp start_session(connection) do
    case SessionSupervisor.start_session(connection) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp try_part(membership) do
    Session.part(membership.server_connection, membership.channel)
  catch
    :exit, _ -> {:error, :not_connected}
  end
end
