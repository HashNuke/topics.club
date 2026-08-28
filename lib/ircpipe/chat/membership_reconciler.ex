defmodule Ircpipe.Chat.MembershipReconciler do
  @moduledoc false

  import Ecto.Query

  alias Ircpipe.Chat.{
    BufferEvents,
    ChannelMembership,
    Message,
    Notification,
    Presence,
    ServerConnection,
    ServerConnectionLock
  }

  alias Ircpipe.Irc.Identifier
  alias Ircpipe.InternalEvent
  alias Ircpipe.InternalEvent.Data
  alias Ircpipe.InternalEvents
  alias Ircpipe.Repo

  def reconcile(%ServerConnection{} = connection, casemapping) do
    assert_no_outer_transaction!()

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
      active_connection = ServerConnectionLock.lock_active!(connection.id)
      lock_memberships(connection)
      Presence.rekey_users(active_connection, casemapping)

      active_connection
      |> all_memberships()
      |> Enum.group_by(&Identifier.key(&1.channel, casemapping))
      |> Enum.flat_map(fn {_key, memberships} -> merge_equivalent(memberships) end)
    else
      raise ArgumentError, "membership reconciliation requires a database transaction"
    end
  end

  def broadcast_losers(%ServerConnection{} = connection, losers) when is_list(losers) do
    _effects =
      ServerConnectionLock.serialize_effects(connection.id, fn active_connection ->
        Enum.each(losers, fn loser ->
          BufferEvents.left(%{
            user_id: active_connection.user_id,
            buffer_id: "channel:#{loser.id}",
            server_connection_id: active_connection.id,
            channel_membership_id: loser.id,
            channel: loser.channel
          })
        end)
      end)

    :ok
  end

  def presence_sync_events_in_transaction(%ServerConnection{} = connection) do
    unless Repo.in_transaction?() do
      raise ArgumentError, "presence snapshots require a database transaction"
    end

    connection
    |> all_memberships()
    |> Enum.filter(&(&1.status == "joined"))
    |> Enum.map(fn membership ->
      occurred_at = DateTime.utc_now(:second)

      InternalEvent.new!(
        "presence_synchronized",
        connection.user_id,
        %{
          connection_id: connection.id,
          membership_id: membership.id,
          users: membership |> Presence.list_users() |> Data.presence_users()
        },
        event_id: "presence_sync:channel:#{membership.id}:#{timestamp(occurred_at)}",
        occurred_at: occurred_at
      )
    end)
  end

  def broadcast_casemapping_change(
        %ServerConnection{} = connection,
        losers,
        presence_sync_events
      )
      when is_list(losers) and is_list(presence_sync_events) do
    _effects =
      ServerConnectionLock.serialize_effects(connection.id, fn active_connection ->
        Enum.each(losers, fn loser ->
          BufferEvents.left(%{
            user_id: active_connection.user_id,
            buffer_id: "channel:#{loser.id}",
            server_connection_id: active_connection.id,
            channel_membership_id: loser.id,
            channel: loser.channel
          })
        end)

        Enum.each(presence_sync_events, &InternalEvents.publish/1)
      end)

    :ok
  end

  defp lock_memberships(connection) do
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

  defp timestamp(%DateTime{} = occurred_at),
    do: DateTime.to_unix(occurred_at, :microsecond)

  defp assert_no_outer_transaction! do
    if Repo.in_transaction?() do
      raise ArgumentError, "cannot reconcile memberships inside an existing transaction"
    end
  end
end
