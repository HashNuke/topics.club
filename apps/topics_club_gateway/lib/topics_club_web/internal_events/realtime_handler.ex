defmodule TopicsClubWeb.InternalEvents.RealtimeHandler do
  @moduledoc false

  alias TopicsClub.Realtime.Event

  def dispatch(%{type: "buffer_left"} = internal) do
    data = internal.data

    payload = %{
      buffer_id: buffer_id(data),
      server_connection_id: data.connection_id,
      channel_membership_id: data.membership_id
    }

    payload = if data.channel, do: Map.put(payload, :channel, data.channel), else: payload
    broadcast(internal, :buffer_left, Event.buffer_left(payload))
  end

  def dispatch(%{type: "buffer_read"} = internal) do
    data = internal.data

    payload = %{
      buffer_id: buffer_id(data),
      server_connection_id: data.connection_id,
      channel_membership_id: data.membership_id,
      unread_count: data.unread_count,
      mention_count: data.mention_count
    }

    broadcast(internal, :buffer_read, Event.buffer_read(payload))
  end

  def dispatch(%{type: "buffer_joined"} = internal) do
    data = internal.data
    event = Event.buffer_joined(data.connection, data.membership, data.status)
    broadcast(internal, :buffer_joined, event)
  end

  def dispatch(%{type: "message_committed"} = internal) do
    data = internal.data
    message = parse_record_timestamps(data.message)
    {buffer_id, extra} = message_destination(data)
    event = Event.message(message, buffer_id, extra) |> stamp(internal)

    Phoenix.PubSub.broadcast(
      TopicsClub.PubSub,
      user_topic(internal.user_id),
      {message_pubsub_event(event), event}
    )
  end

  def dispatch(%{type: "direct_message_thread_changed"} = internal) do
    thread = parse_record_timestamps(internal.data.thread)
    event = Event.direct_message_thread(thread, internal.data.connection)
    broadcast(internal, :direct_message_thread, event)
  end

  def dispatch(%{type: "direct_message_thread_closed"} = internal) do
    thread = parse_record_timestamps(internal.data.thread)
    event = Event.direct_message_closed(thread)
    broadcast(internal, :direct_message_closed, event)
  end

  def dispatch(%{type: "connection_status_changed"} = internal) do
    event = Event.server_status(internal.data.connection, internal.data.status)
    broadcast(internal, :server_status, event)
  end

  def dispatch(%{type: "presence_synchronized"} = internal) do
    data = internal.data

    event =
      Event.presence_sync(%{
        buffer_id: "channel:#{data.membership_id}",
        server_connection_id: data.connection_id,
        channel_membership_id: data.membership_id,
        users: Enum.map(data.users, &parse_record_timestamps/1)
      })

    broadcast(internal, :presence_sync, event)
  end

  def dispatch(%{type: "presence_changed"} = internal) do
    data = internal.data

    event =
      Event.presence_diff(%{
        buffer_id: "channel:#{data.membership_id}",
        server_connection_id: data.connection_id,
        channel_membership_id: data.membership_id,
        diff: parse_record_timestamps(data.diff)
      })

    broadcast(internal, :presence_diff, event)
  end

  defp broadcast(internal, name, event) do
    Phoenix.PubSub.broadcast(
      TopicsClub.PubSub,
      user_topic(internal.user_id),
      {name, stamp(event, internal)}
    )
  end

  defp stamp(event, internal) do
    event
    |> Map.put(:event_id, internal.event_id)
    |> Map.put(:occurred_at, parse_timestamp(internal.occurred_at))
  end

  defp message_destination(%{delivery: "channel", membership: membership}) do
    {"channel:#{membership.id}", %{channel: membership.channel}}
  end

  defp message_destination(%{delivery: "channel_attention", membership: membership}) do
    {"channel:#{membership.id}",
     %{
       channel: membership.channel,
       unread_count: membership.unread_count,
       mention_count: membership.mention_count
     }}
  end

  defp message_destination(%{delivery: "server", connection: connection}) do
    {"server:#{connection.id}", %{mentioned: false}}
  end

  defp message_destination(%{delivery: "direct", thread: thread}) do
    {"direct:#{thread.id}",
     %{peer_nick: thread.peer_nick, blocked: not is_nil(thread.blocked_at)}}
  end

  defp buffer_id(%{membership_id: nil, connection_id: connection_id}),
    do: "server:#{connection_id}"

  defp buffer_id(%{membership_id: membership_id}), do: "channel:#{membership_id}"

  defp message_pubsub_event(%{type: "buffer:error"}), do: :buffer_error
  defp message_pubsub_event(%{type: "buffer:system"}), do: :buffer_system
  defp message_pubsub_event(_event), do: :buffer_message

  defp parse_record_timestamps(record) when is_map(record) do
    Map.new(record, fn
      {key, value}
      when key in [
             :occurred_at,
             :joined_at,
             :left_at,
             :closed_at,
             :blocked_at,
             :last_observed_at
           ] ->
        {key, parse_optional_timestamp(value)}

      {key, value} when is_map(value) ->
        {key, parse_record_timestamps(value)}

      {key, value} ->
        {key, value}
    end)
  end

  defp parse_optional_timestamp(nil), do: nil
  defp parse_optional_timestamp(value), do: parse_timestamp(value)

  defp parse_timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, parsed, 0} -> parsed
      _invalid -> value
    end
  end

  defp parse_timestamp(value), do: value

  defp user_topic(user_id), do: "user:#{user_id}"
end
