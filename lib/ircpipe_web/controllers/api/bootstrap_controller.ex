defmodule IrcpipeWeb.Api.BootstrapController do
  use IrcpipeWeb, :controller

  alias Ircpipe.Chat.ConnectionSnapshot
  alias Ircpipe.Chat.MessageHistory
  alias Ircpipe.Chat.ServerConnection
  alias Ircpipe.Chat.Topics
  alias Ircpipe.Chat.PresenceQueries
  alias Ircpipe.EngineClient
  alias Ircpipe.Irc.Commands
  alias Ircpipe.Notifications.PushRegistrations
  alias Ircpipe.Realtime.Event
  alias Ircpipe.Repo
  alias IrcpipeWeb.Api.BootstrapBuffers
  alias IrcpipeWeb.EngineStatuses

  @message_limit 150

  def show(conn, _params) do
    user = conn.assigns.current_scope.user

    {:ok, snapshot} =
      Repo.transaction(fn ->
        connection_snapshot = ConnectionSnapshot.capture_in_transaction(user)
        connections = connection_snapshot.connections

        %{
          connections: connections,
          direct_message_tombstones: connection_snapshot.direct_message_tombstones,
          connection_reconciliations: connection_snapshot.reconciliations,
          messages_by_buffer: messages_by_buffer(user, connections),
          topics: Topics.list(),
          users_by_buffer: users_by_buffer(connections)
        }
      end)

    ConnectionSnapshot.broadcast_reconciliations(snapshot.connection_reconciliations)
    connections = snapshot.connections

    connections
    |> Enum.filter(&ServerConnection.connect_desired?/1)
    |> Enum.each(&start_session(user, &1))

    statuses = EngineStatuses.fetch(user, connections)

    buffers =
      Enum.flat_map(connections, fn connection ->
        BootstrapBuffers.for_connection(connection, EngineStatuses.get(statuses, connection))
      end)

    active_buffer_id = BootstrapBuffers.active_id(buffers)

    payload = %{
      user: user_json(user),
      push:
        PushRegistrations.session_config(
          conn.assigns.current_scope,
          get_session(conn, :user_token)
        ),
      server_time: DateTime.utc_now(:second),
      connections: Enum.map(connections, &connection_json(&1, EngineStatuses.get(statuses, &1))),
      buffers: buffers,
      direct_message_tombstones: snapshot.direct_message_tombstones,
      active_buffer_id: active_buffer_id,
      messages_by_buffer: snapshot.messages_by_buffer,
      message_cursors_by_buffer: message_cursors_by_buffer(snapshot.messages_by_buffer),
      users_by_buffer: snapshot.users_by_buffer,
      command_catalog: Commands.all(),
      topics: Enum.map(snapshot.topics, &topic_json/1)
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

  defp connection_json(connection, status) do
    %{
      id: connection.id,
      name: connection.name,
      host: connection.host,
      port: connection.port,
      use_tls: connection.use_tls,
      nickname: connection.nickname,
      status: status,
      unread_count: connection.unread_count,
      mention_count: connection.mention_count,
      mention_notifications_enabled: connection.mention_notifications_enabled,
      notification_preference_revision: connection.notification_preference_revision
    }
  end

  defp messages_by_buffer(user, connections) do
    channel_messages =
      connections
      |> Enum.flat_map(&BootstrapBuffers.visible_memberships/1)
      |> Map.new(fn membership ->
        messages =
          user
          |> MessageHistory.list_messages(membership.id, @message_limit)
          |> Enum.map(&message_json(&1, membership))

        {BootstrapBuffers.channel_id(membership), messages}
      end)

    server_messages =
      Map.new(connections, fn connection ->
        buffer_id = BootstrapBuffers.server_id(connection)

        messages =
          user
          |> MessageHistory.list_buffer_messages(buffer_id, limit: @message_limit)
          |> Enum.map(&server_message_json(&1, connection))

        {buffer_id, messages}
      end)

    direct_message_messages =
      connections
      |> Enum.flat_map(& &1.direct_message_threads)
      |> Map.new(fn thread ->
        buffer_id = BootstrapBuffers.direct_message_id(thread)

        messages =
          user
          |> MessageHistory.list_buffer_messages(buffer_id, limit: @message_limit)
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
    Event.message(message, BootstrapBuffers.server_id(connection), %{mentioned: false})
  end

  defp message_json(message, membership) do
    Event.message(message, BootstrapBuffers.channel_id(membership))
  end

  defp users_by_buffer(connections) do
    connections
    |> Enum.flat_map(&BootstrapBuffers.visible_memberships/1)
    |> Map.new(&{BootstrapBuffers.channel_id(&1), PresenceQueries.list_users(&1)})
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

  defp start_session(user, connection) do
    EngineClient.ensure_connection(user.id, connection.id, intent: "restore")
    :ok
  end
end
