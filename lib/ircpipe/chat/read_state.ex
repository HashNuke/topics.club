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
      ServerConnectionLock.lock!(membership.server_connection_id)

      from(m in ChannelMembership, where: m.id == ^membership.id and m.user_id == ^user_id)
      |> Repo.update_all(set: [last_read_at: now, unread_count: 0, mention_count: 0])

      from(n in Notification,
        where:
          n.user_id == ^user_id and n.channel_membership_id == ^membership.id and
            is_nil(n.read_at)
      )
      |> Repo.update_all(set: [read_at: now])
    end)

    BufferEvents.read(%{
      user_id: user_id,
      buffer_id: "channel:#{membership.id}",
      server_connection_id: membership.server_connection_id,
      channel_membership_id: membership.id
    })

    :ok
  end

  def mark(%User{}, %ChannelMembership{}), do: {:error, :invalid_buffer}

  def mark(%User{id: user_id}, %ServerConnection{user_id: user_id} = connection) do
    assert_transaction_owner!()
    now = DateTime.utc_now(:second)

    from(c in ServerConnection, where: c.id == ^connection.id and c.user_id == ^user_id)
    |> Repo.update_all(set: [last_read_at: now, unread_count: 0, mention_count: 0])

    BufferEvents.read(%{
      user_id: user_id,
      buffer_id: "server:#{connection.id}",
      server_connection_id: connection.id,
      channel_membership_id: nil
    })

    :ok
  end

  def mark(%User{}, %ServerConnection{}), do: {:error, :invalid_buffer}

  defp assert_transaction_owner! do
    if Repo.in_transaction?() do
      raise ArgumentError, "cannot mark buffers read inside an existing transaction"
    end
  end
end
