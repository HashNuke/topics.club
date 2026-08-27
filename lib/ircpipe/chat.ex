defmodule Ircpipe.Chat do
  import Ecto.Query

  alias Ircpipe.Accounts.User

  alias Ircpipe.Chat.{
    BufferEvents,
    ChannelMembership,
    ChannelUser,
    MembershipReconciler,
    ServerConnection,
    ServerConnectionLock
  }

  alias Ircpipe.Irc.Identifier
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

  def request_channel_join(user, %ServerConnection{} = connection, channel),
    do: request_channel_join(user, connection, channel, stored_casemapping(connection) || :ascii)

  def request_channel_join(
        %User{id: user_id} = user,
        %ServerConnection{user_id: user_id} = connection,
        channel,
        casemapping
      ) do
    assert_no_outer_transaction!()
    channel = String.trim(channel)

    case Repo.transaction(fn ->
           active_connection = ServerConnectionLock.lock_active!(connection.id)
           losers = MembershipReconciler.reconcile_in_transaction(active_connection, casemapping)

           membership =
             case channel_membership(active_connection, channel, casemapping) do
               %ChannelMembership{} = membership ->
                 attrs =
                   if membership.status == "joined" do
                     %{auto_join: true, left_at: nil, last_error: nil}
                   else
                     %{status: "pending", auto_join: true, left_at: nil, last_error: nil}
                   end

                 membership
                 |> ChannelMembership.changeset(attrs)
                 |> Repo.update!()

               nil ->
                 %ChannelMembership{user_id: user.id, server_connection_id: active_connection.id}
                 |> ChannelMembership.changeset(%{
                   channel: channel,
                   status: "pending",
                   auto_join: true
                 })
                 |> Repo.insert!()
             end

           {membership, losers, active_connection}
         end) do
      {:ok, {membership, losers, active_connection}} ->
        MembershipReconciler.broadcast_losers(active_connection, losers)
        {:ok, membership}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def request_channel_join(%User{}, %ServerConnection{}, _channel, _casemapping),
    do: {:error, :invalid_connection}

  def join_channel(%User{} = user, %ServerConnection{} = connection, channel) do
    with {:ok, pending} <- request_channel_join(user, connection, channel),
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
        case channel_membership(active_connection, channel, casemapping) do
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

      case channel_membership(active_connection, channel, casemapping) do
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

      case channel_membership(active_connection, channel, casemapping) do
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

      case channel_membership(active_connection, channel, casemapping, "joined") do
        %ChannelMembership{} = membership ->
          membership
          |> ChannelMembership.changeset(%{last_error: reason_text(reason)})
          |> update_or_rollback()

        nil ->
          Repo.rollback(:invalid_buffer)
      end
    end)
  end

  def get_membership!(%User{id: user_id}, id) do
    ChannelMembership
    |> where([m], m.user_id == ^user_id and m.id == ^id)
    |> preload(:server_connection)
    |> Repo.one!()
  end

  def get_channel_membership(%ServerConnection{} = connection, channel, casemapping \\ :rfc1459),
    do: channel_membership(connection, channel, casemapping)

  def get_membership_by_channel!(
        %User{id: user_id},
        %ServerConnection{} = connection,
        channel,
        casemapping \\ nil
      ) do
    mapping = casemapping || stored_casemapping(connection) || :ascii

    case channel_membership(connection, channel, mapping) do
      %ChannelMembership{user_id: ^user_id} = membership ->
        Repo.preload(membership, :server_connection)

      _membership ->
        raise Ecto.NoResultsError, queryable: ChannelMembership
    end
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

  defp channel_membership(connection, channel, casemapping, status \\ nil) do
    query =
      from(m in ChannelMembership,
        where: m.server_connection_id == ^connection.id
      )

    query = if status, do: where(query, [m], m.status == ^status), else: query
    key = Identifier.key(channel, casemapping)

    query
    |> Repo.all()
    |> Enum.find(&(Identifier.key(&1.channel, casemapping) == key))
  end

  defp stored_casemapping(%ServerConnection{casemapping: mapping}) when is_binary(mapping) do
    case mapping do
      "ascii" -> :ascii
      "strict_rfc1459" -> :strict_rfc1459
      _mapping -> :rfc1459
    end
  end

  defp stored_casemapping(%ServerConnection{}), do: nil

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
