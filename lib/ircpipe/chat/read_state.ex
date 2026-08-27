defmodule Ircpipe.Chat.ReadState do
  @moduledoc false

  import Ecto.Query

  alias Ircpipe.Accounts.User

  alias Ircpipe.Chat.{
    BufferEvents,
    ChannelMembership,
    Notification,
    ServerConnection,
    ServerConnectionLock
  }

  alias Ircpipe.Repo

  def mark(%User{id: user_id}, %ChannelMembership{user_id: user_id} = membership) do
    assert_transaction_owner!()
    now = DateTime.utc_now(:second)

    Repo.transaction(fn ->
      lock_owned_active!(membership.server_connection_id, user_id)

      {updated_count, _rows} =
        from(m in ChannelMembership,
          where:
            m.id == ^membership.id and m.user_id == ^user_id and
              m.server_connection_id == ^membership.server_connection_id
        )
        |> Repo.update_all(set: [last_read_at: now, unread_count: 0, mention_count: 0])

      if updated_count != 1, do: Repo.rollback(:invalid_buffer)

      from(n in Notification,
        where:
          n.user_id == ^user_id and n.channel_membership_id == ^membership.id and
            is_nil(n.read_at)
      )
      |> Repo.update_all(set: [read_at: now])

      %{
        user_id: user_id,
        buffer_id: "channel:#{membership.id}",
        server_connection_id: membership.server_connection_id,
        channel_membership_id: membership.id
      }
    end)
    |> publish_read()
  end

  def mark(%User{}, %ChannelMembership{}), do: {:error, :invalid_buffer}

  def mark(%User{id: user_id}, %ServerConnection{user_id: user_id} = connection) do
    assert_transaction_owner!()
    now = DateTime.utc_now(:second)

    Repo.transaction(fn ->
      lock_owned_active!(connection.id, user_id)

      {updated_count, _rows} =
        from(c in ServerConnection, where: c.id == ^connection.id and c.user_id == ^user_id)
        |> Repo.update_all(set: [last_read_at: now, unread_count: 0, mention_count: 0])

      if updated_count != 1, do: Repo.rollback(:invalid_buffer)

      %{
        user_id: user_id,
        buffer_id: "server:#{connection.id}",
        server_connection_id: connection.id,
        channel_membership_id: nil
      }
    end)
    |> publish_read()
  end

  def mark(%User{}, %ServerConnection{}), do: {:error, :invalid_buffer}

  defp lock_owned_active!(connection_id, user_id) do
    connection = ServerConnectionLock.lock_active!(connection_id)

    if connection.user_id != user_id, do: Repo.rollback(:invalid_buffer)
    connection
  end

  defp publish_read({:ok, payload}) do
    _effects =
      ServerConnectionLock.serialize_effects(payload.server_connection_id, fn _connection ->
        BufferEvents.read(payload)
      end)

    :ok
  end

  defp publish_read({:error, reason}), do: {:error, reason}

  defp assert_transaction_owner! do
    if Repo.in_transaction?() do
      raise ArgumentError, "cannot mark buffers read inside an existing transaction"
    end
  end
end
