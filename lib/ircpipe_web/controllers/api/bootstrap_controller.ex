defmodule IrcpipeWeb.Api.BootstrapController do
  use IrcpipeWeb, :controller

  alias Ircpipe.Chat
  alias Ircpipe.Irc.Commands
  alias Ircpipe.Irc.Session
  alias Ircpipe.Irc.SessionSupervisor
  alias Ircpipe.Notifications
  alias Ircpipe.Realtime.Event

  @message_limit 150

  def show(conn, _params) do
    user = conn.assigns.current_scope.user
    connections = Chat.list_connections(user)
    topics = Chat.list_topics()
    messages_by_buffer = messages_by_buffer(user, connections)
    users_by_buffer = users_by_buffer(connections)

    Enum.each(connections, &start_session/1)

    buffers = Enum.flat_map(connections, &connection_buffers/1)
    active_buffer_id = active_buffer_id(buffers)

    payload = %{
      user: user_json(user),
      push:
        Notifications.push_config(
          conn.assigns.current_scope,
          get_session(conn, :user_token)
        ),
      server_time: DateTime.utc_now(:second),
      connections: Enum.map(connections, &connection_json/1),
      buffers: buffers,
      direct_message_tombstones: Chat.list_direct_message_tombstones(user),
      active_buffer_id: active_buffer_id,
      messages_by_buffer: messages_by_buffer,
      message_cursors_by_buffer: message_cursors_by_buffer(messages_by_buffer),
      users_by_buffer: users_by_buffer,
      command_catalog: Commands.all(),
      topics: Enum.map(topics, &topic_json/1)
    }

    json(conn, payload)
  end

  defp user_json(user) do
    %{
      id: user.id,
      email: user.email,
      message_retention_days: user.message_retention_days
    }
  end

  defp connection_json(connection) do
    memberships = visible_memberships(connection)

    %{
      id: connection.id,
      name: connection.name,
      host: connection.host,
      port: connection.port,
      use_tls: connection.use_tls,
      nickname: connection.nickname,
      status: Session.status(connection),
      unread_count: connection.unread_count,
      mention_count: connection.mention_count,
      mention_notifications_enabled: connection.mention_notifications_enabled,
      notification_preference_revision: connection.notification_preference_revision,
      channels: Enum.map(memberships, & &1.id),
      direct_messages: Enum.map(connection.direct_message_threads, & &1.id)
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
        status: Session.status(connection),
        unread_count: connection.unread_count,
        mention_count: connection.mention_count,
        mention_notifications_enabled: connection.mention_notifications_enabled,
        notification_preference_revision: connection.notification_preference_revision
      }
      | Enum.map(connection.direct_message_threads, &direct_message_buffer(&1, connection)) ++
          Enum.map(visible_memberships(connection), &channel_buffer(&1, connection))
    ]
  end

  defp direct_message_buffer(thread, connection) do
    %{
      buffer_id: direct_message_buffer_id(thread),
      buffer_type: "direct_message",
      server_connection_id: connection.id,
      channel_membership_id: nil,
      direct_message_thread_id: thread.id,
      direct_message_revision: thread.mutation_revision,
      title: thread.peer_nick,
      subtitle: "on #{connection.host}",
      status: Session.status(connection),
      unread_count: thread.unread_count,
      mention_count: 0,
      account: thread.account,
      hostmask: thread.hostmask,
      blocked: not is_nil(thread.blocked_at)
    }
  end

  defp channel_buffer(membership, connection) do
    %{
      buffer_id: channel_buffer_id(membership),
      buffer_type: "channel",
      server_connection_id: connection.id,
      channel_membership_id: membership.id,
      title: membership.channel,
      subtitle: "on #{connection.host}",
      status: Session.status(connection),
      membership_status: membership.status,
      unread_count: membership.unread_count,
      mention_count: membership.mention_count,
      mention_notifications_enabled: membership.mention_notifications_enabled,
      notification_preference_revision: membership.notification_preference_revision
    }
  end

  defp active_buffer_id(buffers) do
    channel_buffer =
      Enum.find(buffers, &(&1.buffer_type == "channel" and &1.membership_status == "joined")) ||
        Enum.find(buffers, &(&1.buffer_type == "channel"))

    buffer = channel_buffer || List.first(buffers)
    buffer && buffer.buffer_id
  end

  defp messages_by_buffer(user, connections) do
    channel_messages =
      connections
      |> Enum.flat_map(&visible_memberships/1)
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

    direct_message_messages =
      connections
      |> Enum.flat_map(& &1.direct_message_threads)
      |> Map.new(fn thread ->
        buffer_id = direct_message_buffer_id(thread)

        messages =
          user
          |> Chat.list_buffer_messages(buffer_id, limit: @message_limit)
          |> Enum.map(&Event.message(&1, buffer_id, %{peer_nick: thread.peer_nick}))

        {buffer_id, messages}
      end)

    server_messages
    |> Map.merge(direct_message_messages)
    |> Map.merge(channel_messages)
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
    |> Enum.flat_map(&visible_memberships/1)
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
  defp direct_message_buffer_id(thread), do: "direct:#{thread.id}"

  defp visible_memberships(connection) do
    Enum.filter(connection.channel_memberships, &(&1.status in ["pending", "joined"]))
  end

  defp start_session(connection) do
    SessionSupervisor.start_session(connection)
    :ok
  catch
    :exit, _reason -> :ok
  end
end
