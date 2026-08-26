defmodule IrcpipeWeb.Api.TopicController do
  use IrcpipeWeb, :controller

  alias Ircpipe.Chat.Topics
  alias Ircpipe.Irc.{Session, SessionSupervisor}

  def index(conn, _params) do
    json(conn, %{topics: Enum.map(Topics.list(), &topic_json/1)})
  end

  def join(conn, %{"id" => id}) do
    user = conn.assigns.current_scope.user
    topic = Topics.get!(id)

    with {:ok, %{connection: connection, topic: topic}} <- Topics.join(user, topic),
         :ok <- start_session(connection) do
      case try_join(connection, user, topic.channel) do
        {:ok, membership, status} ->
          conn
          |> maybe_accept_queued(status)
          |> json(%{
            topic: topic_json(topic),
            connection: connection_json(connection),
            buffer: channel_buffer_json(connection, membership),
            status: Atom.to_string(status)
          })

        {:error, reason} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: join_error(reason)})
      end
    else
      {:error, reason} ->
        conn
        |> put_status(join_status(reason))
        |> json(%{error: join_error(reason)})
    end
  end

  defp topic_json(topic) do
    %{
      id: topic.id,
      name: topic.name,
      description: topic.description,
      server_host: topic.server_host,
      server_port: topic.server_port,
      use_tls: topic.use_tls,
      channel: topic.channel
    }
  end

  defp connection_json(connection) do
    %{
      id: connection.id,
      name: connection.name,
      host: connection.host,
      port: connection.port,
      use_tls: connection.use_tls,
      nickname: connection.nickname,
      status: Session.status(connection),
      mention_notifications_enabled: connection.mention_notifications_enabled,
      notification_preference_revision: connection.notification_preference_revision
    }
  end

  defp channel_buffer_json(connection, membership) do
    %{
      buffer_id: "channel:#{membership.id}",
      buffer_type: "channel",
      server_connection_id: connection.id,
      channel_membership_id: membership.id,
      title: membership.channel,
      subtitle: "on #{connection.host}",
      status: Session.status(connection),
      unread_count: membership.unread_count,
      mention_count: membership.mention_count,
      mention_notifications_enabled: membership.mention_notifications_enabled,
      notification_preference_revision: membership.notification_preference_revision
    }
  end

  defp try_join(connection, user, channel) do
    Session.request_join(connection, user, channel)
  catch
    :exit, _ -> {:error, :not_connected}
  end

  defp start_session(connection) do
    case SessionSupervisor.start_session(connection) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_accept_queued(conn, :queued), do: put_status(conn, :accepted)
  defp maybe_accept_queued(conn, :sent), do: conn

  defp join_status(:not_connected), do: :service_unavailable
  defp join_status(_reason), do: :unprocessable_entity

  defp join_error(%{code: code}), do: code
  defp join_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp join_error(reason), do: inspect(reason)
end
