defmodule Ircpipe.Chat.MembershipReconciler do
  @moduledoc false

  import Ecto.Query

  alias Ircpipe.Chat.{
    BufferEvents,
    ChannelMembership,
    Message,
    Notification,
    Presence,
    ServerConnection
  }

  alias Ircpipe.Irc.Identifier
  alias Ircpipe.Repo

  def reconcile(%ServerConnection{} = connection, casemapping) do
    case Repo.transaction(fn -> reconcile_in_transaction(connection, casemapping) end) do
      {:ok, losers} ->
        broadcast_losers(connection, losers)
        {:ok, losers}

      error ->
        error
    end
  end

  def reconcile_in_transaction(%ServerConnection{} = connection, casemapping) do
    if Repo.in_transaction?() do
      lock_memberships(connection)

      connection
      |> all_memberships()
      |> Enum.group_by(&Identifier.key(&1.channel, casemapping))
      |> Enum.flat_map(fn {_key, memberships} -> merge_equivalent(memberships) end)
    else
      raise ArgumentError, "membership reconciliation requires a database transaction"
    end
  end

  def broadcast_losers(%ServerConnection{} = connection, losers) when is_list(losers) do
    Enum.each(losers, fn loser ->
      BufferEvents.left(%{
        user_id: connection.user_id,
        buffer_id: "channel:#{loser.id}",
        server_connection_id: connection.id,
        channel_membership_id: loser.id,
        channel: loser.channel
      })
    end)
  end

  defp lock_memberships(connection) do
    ServerConnection
    |> where([server], server.id == ^connection.id)
    |> lock("FOR UPDATE")
    |> Repo.one!()

    ChannelMembership
    |> where([membership], membership.server_connection_id == ^connection.id)
    |> lock("FOR UPDATE")
    |> Repo.all()
  end

  defp all_memberships(connection) do
    ChannelMembership
    |> where([membership], membership.server_connection_id == ^connection.id)
    |> order_by([membership], asc: membership.id)
    |> Repo.all()
  end

  defp merge_equivalent([_membership]), do: []

  defp merge_equivalent(memberships) do
    winner = Enum.min_by(memberships, &{status_rank(&1.status), &1.id})
    losers = Enum.reject(memberships, &(&1.id == winner.id))

    Enum.each(losers, fn loser ->
      from(message in Message, where: message.channel_membership_id == ^loser.id)
      |> Repo.update_all(set: [channel_membership_id: winner.id])

      from(notification in Notification, where: notification.channel_membership_id == ^loser.id)
      |> Repo.update_all(set: [channel_membership_id: winner.id])

      Presence.merge_users(loser, winner)
      Repo.delete!(loser)
    end)

    merged_status = winner.status

    winner
    |> ChannelMembership.changeset(%{
      auto_join: Enum.any?(memberships, & &1.auto_join),
      unread_count: Enum.reduce(memberships, 0, &(&1.unread_count + &2)),
      mention_count: Enum.reduce(memberships, 0, &(&1.mention_count + &2)),
      joined_at:
        memberships
        |> Enum.map(& &1.joined_at)
        |> Enum.reject(&is_nil/1)
        |> Enum.min(fn -> nil end),
      left_at:
        if(merged_status in ["joined", "pending"],
          do: nil,
          else:
            memberships
            |> Enum.map(& &1.left_at)
            |> Enum.reject(&is_nil/1)
            |> Enum.max(fn -> nil end)
        )
    })
    |> Repo.update!()

    losers
  end

  defp status_rank("joined"), do: 0
  defp status_rank("pending"), do: 1
  defp status_rank("left"), do: 2
  defp status_rank("error"), do: 3
end
