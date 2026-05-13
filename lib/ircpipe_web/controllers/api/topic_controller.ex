defmodule IrcpipeWeb.Api.TopicController do
  use IrcpipeWeb, :controller

  alias Ircpipe.Chat
  alias Ircpipe.Irc.{Session, SessionSupervisor}

  def index(conn, _params) do
    json(conn, %{topics: Enum.map(Chat.list_topics(), &topic_json/1)})
  end

  def join(conn, %{"id" => id}) do
    user = conn.assigns.current_scope.user
    topic = Chat.get_topic!(id)

    with {:ok, %{connection: connection, membership: membership, topic: topic}} <-
           Chat.join_topic(user, topic) do
      SessionSupervisor.start_session(connection)
      try_join(connection, membership.channel)

      json(conn, %{
        topic: topic_json(topic),
        connection: connection_json(connection),
        buffer: channel_buffer_json(connection, membership)
      })
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
      status: connection.status
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
      status: connection.status,
      unread_count: membership.unread_count,
      mention_count: membership.mention_count
    }
  end

  defp try_join(connection, channel) do
    case Session.join(connection, channel) do
      :ok -> :ok
      _ -> :ok
    end
  catch
    :exit, _ -> :ok
  end
end
