defmodule Ircpipe.Realtime.Event do
  @moduledoc false

  @version 1

  def message(message, buffer_id, extra \\ %{}) do
    %{
      type: message_type(message),
      version: @version,
      event_id: "message:#{message.id}",
      id: message.id,
      buffer_id: buffer_id,
      channel_membership_id: message.channel_membership_id,
      direct_message_thread_id: message.direct_message_thread_id,
      server_connection_id: message.server_connection_id,
      nick: message.nick,
      hostmask: message.hostmask,
      sender_role: message.sender_role,
      service: message.service,
      metadata: message.metadata || %{},
      body: message.body,
      kind: message.kind,
      mentioned: message.mentioned,
      occurred_at: message.occurred_at
    }
    |> Map.merge(extra)
  end

  def direct_message_thread(thread, connection) do
    occurred_at = DateTime.utc_now(:second)

    %{
      type: "direct_message:thread",
      version: @version,
      event_id:
        "direct_message_thread:#{thread.id}:#{DateTime.to_unix(occurred_at, :microsecond)}",
      revision: thread.mutation_revision,
      buffer: %{
        buffer_id: "direct:#{thread.id}",
        buffer_type: "direct_message",
        server_connection_id: connection.id,
        direct_message_thread_id: thread.id,
        direct_message_revision: thread.mutation_revision,
        title: thread.peer_nick,
        subtitle: "on #{connection.host}",
        peer_nick: thread.peer_nick,
        account: thread.account,
        hostmask: thread.hostmask,
        blocked: not is_nil(thread.blocked_at),
        closed_at: thread.closed_at,
        unread_count: thread.unread_count,
        mention_count: 0
      },
      connection: %{
        id: connection.id,
        name: connection.name,
        host: connection.host,
        port: connection.port,
        use_tls: connection.use_tls,
        nickname: connection.nickname,
        status: connection.status,
        mention_notifications_enabled: connection.mention_notifications_enabled,
        notification_preference_revision: connection.notification_preference_revision
      },
      occurred_at: occurred_at
    }
  end

  def direct_message_closed(thread) do
    occurred_at = DateTime.utc_now(:second)

    %{
      type: "direct_message:closed",
      version: @version,
      event_id:
        "direct_message_closed:#{thread.id}:#{DateTime.to_unix(occurred_at, :microsecond)}",
      buffer_id: "direct:#{thread.id}",
      server_connection_id: thread.server_connection_id,
      direct_message_thread_id: thread.id,
      revision: thread.mutation_revision,
      occurred_at: occurred_at
    }
  end

  def server_status(connection, status \\ nil) do
    occurred_at = DateTime.utc_now(:second)

    %{
      type: "server:status",
      version: @version,
      event_id: "server_status:#{connection.id}:#{DateTime.to_unix(occurred_at, :microsecond)}",
      server_connection_id: connection.id,
      nickname: connection.nickname,
      status: status || connection.status,
      occurred_at: occurred_at
    }
  end

  def server_deleted(connection) do
    occurred_at = DateTime.utc_now(:second)

    %{
      type: "server:deleted",
      version: @version,
      event_id: "server_deleted:#{connection.id}:#{DateTime.to_unix(occurred_at, :microsecond)}",
      server_connection_id: connection.id,
      occurred_at: occurred_at
    }
  end

  def buffer_left(payload) do
    payload = Map.new(payload)
    buffer_id = Map.get(payload, :buffer_id) || Map.get(payload, "buffer_id")
    occurred_at = Map.get(payload, :occurred_at) || DateTime.utc_now(:second)
    event_id = Map.get(payload, :event_id) || "buffer_left:#{buffer_id}:#{timestamp(occurred_at)}"

    Map.merge(payload, %{
      type: "buffer:left",
      version: @version,
      event_id: event_id,
      occurred_at: occurred_at
    })
  end

  defp timestamp(%DateTime{} = occurred_at), do: DateTime.to_unix(occurred_at, :microsecond)
  defp timestamp(occurred_at), do: occurred_at

  def buffer_read(payload) do
    occurred_at = DateTime.utc_now(:second)
    payload = Map.new(payload)

    Map.merge(payload, %{
      type: "buffer:read",
      version: @version,
      event_id:
        "buffer_read:#{Map.get(payload, :buffer_id) || Map.get(payload, "buffer_id")}:#{DateTime.to_unix(occurred_at, :microsecond)}",
      occurred_at: occurred_at,
      unread_count: 0,
      mention_count: 0
    })
  end

  def buffer_joined(connection, membership, status \\ nil) do
    occurred_at = DateTime.utc_now(:second)
    status = status || connection.status

    %{
      type: "buffer:joined",
      version: @version,
      event_id:
        "buffer_joined:channel:#{membership.id}:#{DateTime.to_unix(occurred_at, :microsecond)}",
      buffer: %{
        buffer_id: "channel:#{membership.id}",
        buffer_type: "channel",
        server_connection_id: connection.id,
        channel_membership_id: membership.id,
        title: membership.channel,
        subtitle: "on #{connection.host}",
        status: status,
        membership_status: membership.status,
        unread_count: membership.unread_count,
        mention_count: membership.mention_count,
        mention_notifications_enabled: membership.mention_notifications_enabled,
        notification_preference_revision: membership.notification_preference_revision
      },
      connection: %{
        id: connection.id,
        name: connection.name,
        host: connection.host,
        port: connection.port,
        use_tls: connection.use_tls,
        nickname: connection.nickname,
        status: status,
        mention_notifications_enabled: connection.mention_notifications_enabled,
        notification_preference_revision: connection.notification_preference_revision
      },
      occurred_at: occurred_at
    }
  end

  def presence_sync(payload) do
    occurred_at = DateTime.utc_now(:second)

    payload
    |> Map.new()
    |> Map.merge(%{
      type: "presence:sync",
      version: @version,
      event_id:
        "presence_sync:#{Map.get(payload, :buffer_id) || Map.get(payload, "buffer_id")}:#{DateTime.to_unix(occurred_at, :microsecond)}",
      occurred_at: occurred_at
    })
  end

  def presence_diff(payload) do
    occurred_at = DateTime.utc_now(:second)

    payload
    |> Map.new()
    |> Map.merge(%{
      type: "presence:diff",
      version: @version,
      event_id:
        "presence_diff:#{Map.get(payload, :buffer_id) || Map.get(payload, "buffer_id")}:#{DateTime.to_unix(occurred_at, :microsecond)}",
      occurred_at: occurred_at
    })
  end

  defp message_type(%{kind: "error"}), do: "buffer:error"

  defp message_type(%{kind: kind})
       when kind in ~w(system command join part quit nick topic mode kick),
       do: "buffer:system"

  defp message_type(_message), do: "buffer:message"
end
