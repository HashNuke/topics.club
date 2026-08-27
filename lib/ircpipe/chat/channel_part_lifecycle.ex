defmodule Ircpipe.Chat.ChannelPartLifecycle do
  @moduledoc false

  import Ecto.Query

  alias Ircpipe.Chat.BufferEvents
  alias Ircpipe.Chat.ChannelMembership
  alias Ircpipe.Chat.ChannelUser
  alias Ircpipe.Chat.MembershipLookup
  alias Ircpipe.Chat.ServerConnection
  alias Ircpipe.Chat.ServerConnectionLock
  alias Ircpipe.Repo

  def confirm(%ServerConnection{} = connection, channel, casemapping \\ :rfc1459) do
    assert_no_outer_transaction!()

    Repo.transaction(fn ->
      active_connection = ServerConnectionLock.lock_active!(connection.id)

      case MembershipLookup.find_by_channel(active_connection, channel, casemapping) do
        %ChannelMembership{} = membership ->
          updated =
            membership
            |> ChannelMembership.changeset(%{
              status: "left",
              auto_join: false,
              left_at:
                if(membership.status == "left",
                  do: membership.left_at,
                  else: DateTime.utc_now(:second)
                ),
              last_error: nil
            })
            |> update_or_rollback()

          from(u in ChannelUser, where: u.channel_membership_id == ^updated.id)
          |> Repo.delete_all()

          {updated, membership.status != "left", active_connection}

        nil ->
          Repo.rollback(:invalid_buffer)
      end
    end)
    |> case do
      {:ok, {updated, broadcast?, active_connection}} ->
        if broadcast? do
          _effects =
            ServerConnectionLock.serialize_effects(active_connection.id, fn effect_connection ->
              BufferEvents.left(%{
                user_id: effect_connection.user_id,
                buffer_id: "channel:#{updated.id}",
                server_connection_id: effect_connection.id,
                channel_membership_id: updated.id
              })
            end)
        end

        {:ok, updated}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def reject(%ServerConnection{} = connection, channel, reason, casemapping \\ :rfc1459) do
    assert_no_outer_transaction!()

    Repo.transaction(fn ->
      active_connection = ServerConnectionLock.lock_active!(connection.id)

      case MembershipLookup.find_by_channel(active_connection, channel, casemapping, "joined") do
        %ChannelMembership{} = membership ->
          membership
          |> ChannelMembership.changeset(%{last_error: reason_text(reason)})
          |> update_or_rollback()

        nil ->
          Repo.rollback(:invalid_buffer)
      end
    end)
  end

  defp reason_text(reason) when is_binary(reason), do: reason
  defp reason_text(reason), do: inspect(reason)

  defp update_or_rollback(changeset) do
    case Repo.update(changeset) do
      {:ok, updated} -> updated
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp assert_no_outer_transaction! do
    if Repo.in_transaction?() do
      raise ArgumentError, "cannot mutate channel memberships inside an existing transaction"
    end
  end
end
