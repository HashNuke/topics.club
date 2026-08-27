defmodule Ircpipe.Chat.CommandMessages do
  @moduledoc false

  alias Ircpipe.Accounts.User

  alias Ircpipe.Chat.{
    BufferEvents,
    ChannelMembership,
    Message,
    Retention,
    ServerConnection
  }

  alias Ircpipe.Repo

  def record(%ServerConnection{} = connection, buffer_id, body, metadata) do
    assert_no_outer_transaction!()
    membership = membership_for_buffer(connection, buffer_id)
    user = Repo.get!(User, connection.user_id)

    Repo.transaction(fn ->
      {:ok, message} =
        %Message{
          user_id: connection.user_id,
          server_connection_id: connection.id,
          channel_membership_id: membership && membership.id
        }
        |> Message.changeset(%{
          kind: "command",
          nick: connection.nickname,
          metadata: stringify_metadata(metadata),
          body: body,
          mentioned: false,
          occurred_at: DateTime.utc_now(:second)
        })
        |> Repo.insert()

      Retention.prune(user)
      message
    end)
    |> case do
      {:ok, message} ->
        BufferEvents.command_message(message, membership, connection)
        {:ok, message}

      error ->
        error
    end
  end

  def update(%Message{} = message, metadata) when is_map(metadata) do
    assert_no_outer_transaction!()
    merged_metadata = Map.merge(message.metadata || %{}, stringify_metadata(metadata))

    Repo.transaction(fn ->
      {:ok, message} =
        message
        |> Message.changeset(%{metadata: merged_metadata})
        |> Repo.update()

      connection = Repo.get!(ServerConnection, message.server_connection_id)
      membership = membership_for_message(message)
      {message, membership, connection}
    end)
    |> case do
      {:ok, {message, membership, connection}} ->
        BufferEvents.command_message(message, membership, connection)
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
