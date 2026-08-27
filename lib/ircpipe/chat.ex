defmodule Ircpipe.Chat do
  import Ecto.Query

  alias Ircpipe.Accounts.User

  alias Ircpipe.Chat.{
    BufferEvents,
    ChannelJoinRequest,
    ChannelMembership,
    ChannelUser,
    MembershipLookup,
    ServerConnection,
    ServerConnectionLock
  }

  alias Ircpipe.Repo

  def update_connection_casemapping(%ServerConnection{} = connection, casemapping) do
    assert_no_outer_transaction!()
    mapping = Atom.to_string(casemapping)

    Repo.transaction(fn ->
      connection.id
      |> ServerConnectionLock.lock_active!()
      |> Ecto.Changeset.change(casemapping: mapping)
      |> update_or_rollback()
    end)
  end

  def join_channel(%User{} = user, %ServerConnection{} = connection, channel) do
    with {:ok, pending} <- ChannelJoinRequest.request(user, connection, channel),
         {:ok, membership} <- confirm_channel_join(connection, pending.channel) do
      {:ok, membership}
    end
  end

  def confirm_channel_join(
        %ServerConnection{} = connection,
        channel,
        casemapping \\ :rfc1459,
        connection_status \\ nil
      ) do
    assert_no_outer_transaction!()
    now = DateTime.utc_now(:second)

    Repo.transaction(fn ->
      active_connection = ServerConnectionLock.lock_active!(connection.id)

      {membership, broadcast?} =
        case MembershipLookup.find_by_channel(active_connection, channel, casemapping) do
          %ChannelMembership{} = membership ->
            updated =
              membership
              |> ChannelMembership.changeset(%{
                status: "joined",
                auto_join: membership.auto_join,
                joined_at: if(membership.status == "joined", do: membership.joined_at, else: now),
                left_at: nil,
                last_error: nil
              })
              |> update_or_rollback()

            {updated, membership.status != "joined"}

          nil ->
            inserted =
              %ChannelMembership{
                user_id: active_connection.user_id,
                server_connection_id: active_connection.id
              }
              |> ChannelMembership.changeset(%{
                channel: channel,
                status: "joined",
                auto_join: false,
                joined_at: now
              })
              |> insert_or_rollback()

            {inserted, true}
        end

      {membership, broadcast?, active_connection}
    end)
    |> case do
      {:ok, {membership, broadcast?, active_connection}} ->
        if broadcast? do
          _effects =
            ServerConnectionLock.serialize_effects(active_connection.id, fn effect_connection ->
              BufferEvents.joined(effect_connection, membership, connection_status)
            end)
        end

        {:ok, membership}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def reject_channel_join(
        %ServerConnection{} = connection,
        channel,
        reason,
        casemapping \\ :rfc1459
      ) do
    assert_no_outer_transaction!()

    Repo.transaction(fn ->
      active_connection = ServerConnectionLock.lock_active!(connection.id)

      case MembershipLookup.find_by_channel(active_connection, channel, casemapping) do
        %ChannelMembership{} = membership ->
          rejected =
            membership
            |> ChannelMembership.changeset(%{
              status: "error",
              auto_join: false,
              last_error: reason_text(reason)
            })
            |> update_or_rollback()

          {rejected, active_connection}

        nil ->
          Repo.rollback(:invalid_buffer)
      end
    end)
    |> case do
      {:ok, {rejected, active_connection}} ->
        _effects =
          ServerConnectionLock.serialize_effects(active_connection.id, fn effect_connection ->
            BufferEvents.left(%{
              user_id: effect_connection.user_id,
              buffer_id: "channel:#{rejected.id}",
              server_connection_id: effect_connection.id,
              channel_membership_id: rejected.id,
              channel: rejected.channel
            })
          end)

        {:ok, rejected}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def confirm_channel_left(%ServerConnection{} = connection, channel, casemapping \\ :rfc1459) do
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

  def reject_channel_part(
        %ServerConnection{} = connection,
        channel,
        reason,
        casemapping \\ :rfc1459
      ) do
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

  def leave_channel(%User{id: user_id}, %ChannelMembership{} = membership) do
    if membership.user_id == user_id do
      connection = Repo.get!(ServerConnection, membership.server_connection_id)

      case confirm_channel_left(connection, membership.channel) do
        {:ok, _membership} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :invalid_buffer}
    end
  end

  defp reason_text(reason) when is_binary(reason), do: reason
  defp reason_text(reason), do: inspect(reason)

  defp update_or_rollback(changeset) do
    case Repo.update(changeset) do
      {:ok, updated} -> updated
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp insert_or_rollback(changeset) do
    case Repo.insert(changeset) do
      {:ok, inserted} -> inserted
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp assert_no_outer_transaction! do
    if Repo.in_transaction?() do
      raise ArgumentError, "cannot mutate channel memberships inside an existing transaction"
    end
  end
end
