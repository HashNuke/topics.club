defmodule Ircpipe.Chat.CommandMessages do
  @moduledoc false

  alias Ircpipe.Accounts.User

  alias Ircpipe.Chat.{
    BufferEvents,
    ChannelMembership,
    Message,
    Retention,
    ServerConnection,
    ServerConnectionLock
  }

  alias Ircpipe.Repo

  def record(%ServerConnection{} = connection, buffer_id, body, metadata) do
    assert_no_outer_transaction!()
    membership = membership_for_buffer(connection, buffer_id)
    user = Repo.get!(User, connection.user_id)

    Repo.transaction(fn ->
      active_connection = ServerConnectionLock.lock_active!(connection.id)

      {:ok, message} =
        %Message{
          user_id: active_connection.user_id,
          server_connection_id: active_connection.id,
          channel_membership_id: membership && membership.id
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
            BufferEvents.command_message(message, membership, effect_connection)
          end)

        {:ok, message}

      error ->
        error
    end
  end

  def update(%Message{} = message, metadata) when is_map(metadata) do
    assert_no_outer_transaction!()
    merged_metadata = Map.merge(message.metadata || %{}, stringify_metadata(metadata))

    Repo.transaction(fn ->
      connection = ServerConnectionLock.lock_active!(message.server_connection_id)

      {:ok, message} =
        message
        |> Message.changeset(%{metadata: merged_metadata})
        |> Repo.update()

      membership = membership_for_message(message)
      {message, membership, connection}
    end)
    |> case do
      {:ok, {message, membership, connection}} ->
        _effects =
          ServerConnectionLock.serialize_effects(connection.id, fn effect_connection ->
            BufferEvents.command_message(message, membership, effect_connection)
          end)

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

  defp membership_for_buffer(
         %ServerConnection{id: connection_id},
         "channel:" <> membership_id
       ) do
    Repo.get_by!(ChannelMembership, id: membership_id, server_connection_id: connection_id)
  end

  defp membership_for_buffer(
         %ServerConnection{id: connection_id},
         "server:" <> connection_id_text
       )
       when is_binary(connection_id_text) do
    if Integer.to_string(connection_id) == connection_id_text,
      do: nil,
      else: raise(Ecto.NoResultsError, queryable: ServerConnection)
  end

  defp membership_for_buffer(%ServerConnection{}, _buffer_id),
    do: raise(Ecto.NoResultsError, queryable: ChannelMembership)

  defp membership_for_message(%Message{channel_membership_id: nil}), do: nil

  defp membership_for_message(%Message{channel_membership_id: membership_id}),
    do: Repo.get!(ChannelMembership, membership_id)
end
