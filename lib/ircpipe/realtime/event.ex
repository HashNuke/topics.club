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
      server_connection_id: message.server_connection_id,
      nick: message.nick,
      hostmask: message.hostmask,
      sender_role: message.sender_role,
      service: message.service,
      body: message.body,
      kind: message.kind,
      mentioned: message.mentioned,
      occurred_at: message.occurred_at
    }
    |> Map.merge(extra)
  end

  def notification_mention(message_event) do
    message_event
    |> Map.merge(%{
      type: "notification:mention",
      event_id: "notification_mention:#{message_event.event_id}"
    })
  end

  def server_status(connection) do
    occurred_at = DateTime.utc_now(:second)

    %{
      type: "server:status",
      version: @version,
      event_id: "server_status:#{connection.id}:#{DateTime.to_unix(occurred_at, :microsecond)}",
      server_connection_id: connection.id,
      status: connection.status,
      occurred_at: occurred_at
    }
  end

  def buffer_left(payload) do
    occurred_at = DateTime.utc_now(:second)
    payload = Map.new(payload)

    Map.merge(payload, %{
      type: "buffer:left",
      version: @version,
      event_id:
        "buffer_left:#{Map.get(payload, :buffer_id) || Map.get(payload, "buffer_id")}:#{DateTime.to_unix(occurred_at, :microsecond)}",
      occurred_at: occurred_at
    })
  end

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

  def buffer_joined(connection, membership) do
    occurred_at = DateTime.utc_now(:second)

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
        status: connection.status,
        unread_count: membership.unread_count,
        mention_count: membership.mention_count
      },
      connection: %{
        id: connection.id,
        name: connection.name,
        host: connection.host,
        port: connection.port,
        use_tls: connection.use_tls,
        nickname: connection.nickname,
        status: connection.status
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
