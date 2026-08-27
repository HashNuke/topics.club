defmodule Ircpipe.Chat.BufferEvents do
  @moduledoc false

  alias Ircpipe.Chat.{
    ChannelMembership,
    DirectMessageThread,
    Message,
    ServerConnection,
    ServerConnectionLock
  }

  alias Ircpipe.Realtime.Event
  alias Ircpipe.Repo

  def left(payload) when is_map(payload) do
    broadcast_payload(:buffer_left, payload, &Event.buffer_left/1)
  end

  def read(payload) when is_map(payload) do
    broadcast_payload(:buffer_read, payload, &Event.buffer_read/1)
  end

  def joined(
        %ServerConnection{} = connection,
        %ChannelMembership{} = membership,
        status \\ nil
      ) do
    ensure_after_commit!(connection.id)

    Phoenix.PubSub.broadcast(
      Ircpipe.PubSub,
      "user:#{connection.user_id}",
      {:buffer_joined, Event.buffer_joined(connection, membership, status || connection.status)}
    )
  end

  def message(
        %Message{} = message,
        %ChannelMembership{} = membership,
        %ServerConnection{} = connection
      ) do
    ensure_after_commit!(connection.id)
    payload = Event.message(message, "channel:#{membership.id}", %{channel: membership.channel})

    Phoenix.PubSub.broadcast(
      Ircpipe.PubSub,
      "user:#{connection.user_id}",
      {:irc_message, payload}
    )

    Phoenix.PubSub.broadcast(
      Ircpipe.PubSub,
      "user:#{connection.user_id}",
      {pubsub_event(payload), payload}
    )
  end

  def server_message(%Message{} = message, %ServerConnection{} = connection) do
    ensure_after_commit!(connection.id)
    event = Event.message(message, "server:#{connection.id}", %{mentioned: false})

    Phoenix.PubSub.broadcast(
      Ircpipe.PubSub,
      "user:#{connection.user_id}",
      {pubsub_event(event), event}
    )
  end

  def direct_message_thread(%DirectMessageThread{} = thread) do
    ensure_after_commit!(thread.server_connection_id)
    connection = Repo.get!(ServerConnection, thread.server_connection_id)
    event = Event.direct_message_thread(thread, connection)
    maybe_pause_direct_message_thread_broadcast(thread)

    Phoenix.PubSub.broadcast(
      Ircpipe.PubSub,
      "user:#{thread.user_id}",
      {:direct_message_thread, event}
    )
  end

  def direct_message_closed(%DirectMessageThread{} = thread) do
    ensure_after_commit!(thread.server_connection_id)
    maybe_pause_direct_message_closed_broadcast(thread)

    Phoenix.PubSub.broadcast(
      Ircpipe.PubSub,
      "user:#{thread.user_id}",
      {:direct_message_closed, Event.direct_message_closed(thread)}
    )
  end

  def direct_message(%Message{} = message, %DirectMessageThread{} = thread) do
    ensure_after_commit!(thread.server_connection_id)

    event =
      Event.message(message, "direct:#{thread.id}", %{
        peer_nick: thread.peer_nick,
        blocked: not is_nil(thread.blocked_at)
      })

    Phoenix.PubSub.broadcast(
      Ircpipe.PubSub,
      "user:#{thread.user_id}",
      {pubsub_event(event), event}
    )

    event
  end

  def command_message(%Message{} = message, nil, %ServerConnection{} = connection),
    do: server_message(message, connection)

  def command_message(
        %Message{} = message,
        %ChannelMembership{} = membership,
        %ServerConnection{} = connection
      ),
      do: message(message, membership, connection)

  defp broadcast_payload(event_name, payload, event_builder) do
    connection_id = Map.fetch!(payload, :server_connection_id)
    ensure_after_commit!(connection_id)
    user_id = Map.fetch!(payload, :user_id)

    event =
      payload
      |> event_builder.()
      |> Map.drop([:user_id])

    Phoenix.PubSub.broadcast(
      Ircpipe.PubSub,
      "user:#{user_id}",
      {event_name, event}
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

  defp pubsub_event(%{type: "buffer:error"}), do: :buffer_error
  defp pubsub_event(%{type: "buffer:system"}), do: :buffer_system
  defp pubsub_event(_event), do: :buffer_message

  defp ensure_after_commit!(connection_id) do
    if Repo.in_transaction?() and not ServerConnectionLock.effects_lock_held?(connection_id) do
      raise ArgumentError, "buffer events must be published after the transaction commits"
    end
  end
end
