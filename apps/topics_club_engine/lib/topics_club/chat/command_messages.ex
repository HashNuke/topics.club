defmodule TopicsClub.Chat.CommandMessages do
  @moduledoc false

  alias TopicsClub.Accounts.User

  alias TopicsClub.Chat.{
    BufferEvents,
    ChannelMembership,
    DirectMessageThread,
    IrcIngestionEffect,
    Message,
    Retention,
    ServerConnection,
    ServerConnectionLock
  }

  alias TopicsClub.Repo

  def record(%ServerConnection{} = connection, buffer_id, body, metadata, ingestion \\ nil) do
    assert_no_outer_transaction!()
    buffer = command_buffer(connection, buffer_id)
    {membership_id, thread_id} = message_buffer_ids(buffer)
    user = Repo.get!(User, connection.user_id)

    Repo.transaction(fn ->
      active_connection = ServerConnectionLock.lock_active!(connection.id)

      if IrcIngestionEffect.claim(active_connection, ingestion) == :duplicate do
        Repo.rollback(:duplicate_irc_ingestion)
      end

      {:ok, message} =
        %Message{
          user_id: active_connection.user_id,
          server_connection_id: active_connection.id,
          channel_membership_id: membership_id,
          direct_message_thread_id: thread_id
        }
        |> Message.changeset(%{
          kind: "command",
          nick: active_connection.nickname,
          metadata: stringify_metadata(metadata),
          body: body,
          mentioned: false,
          occurred_at: DateTime.utc_now(:second)
        })
        |> Repo.insert()

      Retention.prune(user)
      {message, active_connection}
    end)
    |> case do
      {:ok, {message, active_connection}} ->
        _effects =
          ServerConnectionLock.serialize_effects(active_connection.id, fn effect_connection ->
            BufferEvents.command_message(message, buffer, effect_connection)
          end)

        {:ok, message}

      {:error, :duplicate_irc_ingestion} ->
        {:ok, nil}

      error ->
        error
    end
  end

  def update(%Message{} = message, metadata) when is_map(metadata) do
    assert_no_outer_transaction!()
    metadata = stringify_metadata(metadata)

    Repo.transaction(fn ->
      connection = ServerConnectionLock.lock_active!(message.server_connection_id)

      current =
        Repo.get_by(Message,
          id: message.id,
          server_connection_id: message.server_connection_id
        ) || Repo.rollback(:message_not_found)

      merged_metadata = Map.merge(current.metadata || %{}, metadata)
      changed? = merged_metadata != current.metadata

      updated =
        if changed? do
          {:ok, updated} =
            current
            |> Message.changeset(%{metadata: merged_metadata})
            |> Repo.update()

          updated
        else
          current
        end

      buffer = command_buffer(updated)
      {updated, buffer, connection, changed?}
    end)
    |> case do
      {:ok, {message, buffer, connection, changed?}} ->
        if changed? do
          _effects =
            ServerConnectionLock.serialize_effects(connection.id, fn effect_connection ->
              BufferEvents.command_message(message, buffer, effect_connection)
            end)
        end

        {:ok, message}

      error ->
        error
    end
  end

  defp stringify_metadata(metadata) when is_map(metadata) do
    Map.new(metadata, fn {key, value} -> {to_string(key), value} end)
  end

  defp stringify_metadata(_metadata), do: %{}

  defp assert_no_outer_transaction! do
    if Repo.in_transaction?() do
      raise ArgumentError, "cannot persist command messages inside an existing transaction"
    end
  end

  defp command_buffer(
         %ServerConnection{id: connection_id},
         "channel:" <> membership_id
       ) do
    Repo.get_by!(ChannelMembership, id: membership_id, server_connection_id: connection_id)
  end

  defp command_buffer(
         %ServerConnection{id: connection_id},
         "direct:" <> thread_id
       ) do
    Repo.get_by!(DirectMessageThread, id: thread_id, server_connection_id: connection_id)
  end

  defp command_buffer(
         %ServerConnection{id: connection_id},
         "server:" <> connection_id_text
       )
       when is_binary(connection_id_text) do
    if Integer.to_string(connection_id) == connection_id_text,
      do: nil,
      else: raise(Ecto.NoResultsError, queryable: ServerConnection)
  end

  defp command_buffer(%ServerConnection{}, _buffer_id),
    do: raise(Ecto.NoResultsError, queryable: ChannelMembership)

  defp command_buffer(%Message{direct_message_thread_id: thread_id})
       when not is_nil(thread_id),
       do: Repo.get!(DirectMessageThread, thread_id)

  defp command_buffer(%Message{channel_membership_id: nil}), do: nil

  defp command_buffer(%Message{channel_membership_id: membership_id}),
    do: Repo.get!(ChannelMembership, membership_id)

  defp message_buffer_ids(%ChannelMembership{id: membership_id}), do: {membership_id, nil}
  defp message_buffer_ids(%DirectMessageThread{id: thread_id}), do: {nil, thread_id}
  defp message_buffer_ids(nil), do: {nil, nil}
end
