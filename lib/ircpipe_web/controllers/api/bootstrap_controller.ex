defmodule IrcpipeWeb.Api.BootstrapController do
  use IrcpipeWeb, :controller

  alias Ircpipe.Chat
  alias Ircpipe.Realtime.Event

  @message_limit 150

  def show(conn, _params) do
    user = conn.assigns.current_scope.user
    connections = Chat.list_connections(user)
    topics = Chat.list_topics()
    buffers = Enum.flat_map(connections, &connection_buffers/1)
    active_buffer_id = active_buffer_id(buffers)
    messages_by_buffer = messages_by_buffer(user, connections)

    json(conn, %{
      user: user_json(user),
      notification_state: "default",
      server_time: DateTime.utc_now(:second),
      connections: Enum.map(connections, &connection_json/1),
      buffers: buffers,
      active_buffer_id: active_buffer_id,
      messages_by_buffer: messages_by_buffer,
      message_cursors_by_buffer: message_cursors_by_buffer(messages_by_buffer),
      users_by_buffer: users_by_buffer(connections),
      topics: Enum.map(topics, &topic_json/1)
    })
  end

  defp user_json(user) do
    %{
      id: user.id,
      email: user.email,
      message_retention_days: user.message_retention_days
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
      status: connection.status,
      unread_count: connection.unread_count,
      mention_count: connection.mention_count,
      channels: Enum.map(connection.channel_memberships, & &1.id)
    }
  end

  defp connection_buffers(connection) do
    [
      %{
        buffer_id: server_buffer_id(connection),
        buffer_type: "server",
        server_connection_id: connection.id,
        channel_membership_id: nil,
        title: connection.host,
        subtitle: connection.name,
        status: connection.status,
        unread_count: connection.unread_count,
        mention_count: connection.mention_count
      }
      | Enum.map(connection.channel_memberships, &channel_buffer(&1, connection))
    ]
  end

  defp channel_buffer(membership, connection) do
    %{
      buffer_id: channel_buffer_id(membership),
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

  defp active_buffer_id(buffers) do
    channel_buffer = Enum.find(buffers, &(&1.buffer_type == "channel"))
    buffer = channel_buffer || List.first(buffers)
    buffer && buffer.buffer_id
  end

  defp messages_by_buffer(user, connections) do
    channel_messages =
      connections
      |> Enum.flat_map(& &1.channel_memberships)
      |> Map.new(fn membership ->
        messages =
          user
          |> Chat.list_messages(membership.id, @message_limit)
          |> Enum.map(&message_json(&1, membership))

        {channel_buffer_id(membership), messages}
      end)

    server_messages =
      Map.new(connections, fn connection ->
        buffer_id = server_buffer_id(connection)

        messages =
          user
          |> Chat.list_buffer_messages(buffer_id, limit: @message_limit)
          |> Enum.map(&server_message_json(&1, connection))

        {buffer_id, messages}
      end)

    Map.merge(server_messages, channel_messages)
  end

  defp message_cursors_by_buffer(messages_by_buffer) do
    Map.new(messages_by_buffer, fn {buffer_id, messages} ->
      latest = List.last(messages)
      {buffer_id, latest && latest.id}
    end)
  end

  defp server_message_json(message, connection) do
    Event.message(message, server_buffer_id(connection), %{mentioned: false})
  end

  defp message_json(message, membership) do
    Event.message(message, channel_buffer_id(membership))
  end

  defp users_by_buffer(connections) do
    connections
    |> Enum.flat_map(& &1.channel_memberships)
    |> Map.new(&{channel_buffer_id(&1), Chat.list_channel_users(&1)})
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

  defp server_buffer_id(connection), do: "server:#{connection.id}"
  defp channel_buffer_id(membership), do: "channel:#{membership.id}"
end
