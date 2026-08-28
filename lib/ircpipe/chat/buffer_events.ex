defmodule Ircpipe.Chat.BufferEvents do
  @moduledoc false

  alias Ircpipe.Chat.{
    ChannelMembership,
    DirectMessageThread,
    Message,
    ServerConnection,
    ServerConnectionLock
  }

  alias Ircpipe.InternalEvent.Data
  alias Ircpipe.InternalEvents
  alias Ircpipe.Repo

  def left(payload) when is_map(payload) do
    connection_id = value!(payload, :server_connection_id)
    ensure_after_commit!(connection_id)
    occurred_at = value(payload, :occurred_at) || DateTime.utc_now(:second)

    InternalEvents.emit(
      "buffer_left",
      value!(payload, :user_id),
      %{
        connection_id: connection_id,
        membership_id: value(payload, :channel_membership_id),
        channel: value(payload, :channel)
      },
      event_id:
        value(payload, :event_id) ||
          "buffer_left:#{buffer_key(value(payload, :channel_membership_id), connection_id)}:#{timestamp(occurred_at)}",
      occurred_at: occurred_at
    )
  end

  def read(payload) when is_map(payload) do
    connection_id = value!(payload, :server_connection_id)
    ensure_after_commit!(connection_id)
    occurred_at = DateTime.utc_now(:second)

    InternalEvents.emit(
      "buffer_read",
      value!(payload, :user_id),
      %{
        connection_id: connection_id,
        membership_id: value(payload, :channel_membership_id),
        unread_count: value(payload, :unread_count) || 0,
        mention_count: value(payload, :mention_count) || 0
      },
      event_id:
        "buffer_read:#{buffer_key(value(payload, :channel_membership_id), connection_id)}:#{timestamp(occurred_at)}",
      occurred_at: occurred_at
    )
  end

  def joined(
        %ServerConnection{} = connection,
        %ChannelMembership{} = membership,
        status \\ nil
      ) do
    ensure_after_commit!(connection.id)
    occurred_at = DateTime.utc_now(:second)

    InternalEvents.emit(
      "buffer_joined",
      connection.user_id,
      %{
        connection: Data.connection(connection),
        membership: Data.membership(membership),
        status: status || connection.status
      },
      event_id: "buffer_joined:channel:#{membership.id}:#{timestamp(occurred_at)}",
      occurred_at: occurred_at
    )
  end

  def message(
        %Message{} = message,
        %ChannelMembership{} = membership,
        %ServerConnection{} = connection
      ) do
    emit_message(message, connection.user_id, %{
      delivery: "channel",
      connection: Data.connection(connection),
      membership: Data.membership(membership)
    })
  end

  def attention_message(
        %Message{} = message,
        %ChannelMembership{} = membership,
        %ServerConnection{} = connection
      ) do
    emit_message(message, connection.user_id, %{
      delivery: "channel_attention",
      connection: Data.connection(connection),
      membership: Data.membership(membership)
    })
  end

  def server_message(%Message{} = message, %ServerConnection{} = connection) do
    emit_message(message, connection.user_id, %{
      delivery: "server",
      connection: Data.connection(connection)
    })
  end

  def direct_message_thread(%DirectMessageThread{} = thread) do
    ensure_after_commit!(thread.server_connection_id)
    connection = Repo.get!(ServerConnection, thread.server_connection_id)
    maybe_pause_direct_message_thread_broadcast(thread)
    occurred_at = DateTime.utc_now(:second)

    InternalEvents.emit(
      "direct_message_thread_changed",
      thread.user_id,
      %{thread: Data.thread(thread), connection: Data.connection(connection)},
      event_id: "direct_message_thread:#{thread.id}:#{thread.mutation_revision}",
      occurred_at: occurred_at
    )
  end

  def direct_message_closed(%DirectMessageThread{} = thread) do
    ensure_after_commit!(thread.server_connection_id)
    maybe_pause_direct_message_closed_broadcast(thread)
    occurred_at = DateTime.utc_now(:second)

    InternalEvents.emit(
      "direct_message_thread_closed",
      thread.user_id,
      %{thread: Data.thread(thread)},
      event_id: "direct_message_closed:#{thread.id}:#{thread.mutation_revision}",
      occurred_at: occurred_at
    )
  end

  def direct_message(%Message{} = message, %DirectMessageThread{} = thread) do
    emit_message(message, thread.user_id, %{
      delivery: "direct",
      thread: Data.thread(thread)
    })
  end

  def command_message(%Message{} = message, nil, %ServerConnection{} = connection),
    do: server_message(message, connection)

  def command_message(
        %Message{} = message,
        %ChannelMembership{} = membership,
        %ServerConnection{} = connection
      ),
      do: message(message, membership, connection)

  defp emit_message(%Message{} = message, user_id, data) do
    ensure_after_commit!(message.server_connection_id)

    InternalEvents.emit(
      "message_committed",
      user_id,
      Map.put(data, :message, Data.message(message)),
      event_id: "message:#{message.id}",
      occurred_at: message.occurred_at
    )
  end

  defp maybe_pause_direct_message_thread_broadcast(thread) do
    case Application.get_env(:ircpipe, :pause_direct_message_thread_broadcast) do
      {pid, revision} when is_pid(pid) and revision == thread.mutation_revision ->
        send(pid, {:direct_message_thread_broadcast_paused, self(), thread.id, revision})

        receive do
          {:continue_direct_message_thread_broadcast, ^revision} -> :ok
        end

      _other ->
        :ok
    end
  end

  defp maybe_pause_direct_message_closed_broadcast(thread) do
    case Application.get_env(:ircpipe, :pause_direct_message_closed_broadcast) do
      {pid, revision} when is_pid(pid) and revision == thread.mutation_revision ->
        send(pid, {:direct_message_closed_broadcast_paused, self(), thread.id, revision})

        receive do
          {:continue_direct_message_closed_broadcast, ^revision} -> :ok
        end

      _other ->
        :ok
    end
  end

  defp buffer_key(nil, connection_id), do: "server:#{connection_id}"
  defp buffer_key(membership_id, _connection_id), do: "channel:#{membership_id}"

  defp timestamp(%DateTime{} = occurred_at), do: DateTime.to_unix(occurred_at, :microsecond)
  defp timestamp(occurred_at) when is_binary(occurred_at), do: occurred_at

  defp value(payload, key) do
    case Map.fetch(payload, key) do
      {:ok, value} -> value
      :error -> Map.get(payload, Atom.to_string(key))
    end
  end

  defp value!(payload, key) do
    case value(payload, key) do
      nil -> raise KeyError, key: key, term: payload
      value -> value
    end
  end

  defp ensure_after_commit!(connection_id) do
    if Repo.in_transaction?() and not ServerConnectionLock.effects_lock_held?(connection_id) do
      raise ArgumentError, "buffer events must be published after the transaction commits"
    end
  end
end
