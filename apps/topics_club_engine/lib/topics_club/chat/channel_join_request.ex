defmodule TopicsClub.Chat.ChannelJoinRequest do
  @moduledoc false

  import Ecto.Query

  alias TopicsClub.Accounts.User

  alias TopicsClub.Chat.{
    ChannelMembership,
    MembershipLookup,
    MembershipReconciler,
    ServerConnection,
    ServerConnectionLock
  }

  alias TopicsClub.Repo

  def prepare_for_fresh_connection(%ServerConnection{} = connection) do
    assert_no_outer_transaction!()

    Repo.transaction(fn ->
      active_connection = ServerConnectionLock.lock_active!(connection.id)

      ChannelMembership
      |> where(
        [membership],
        membership.server_connection_id == ^active_connection.id and membership.auto_join and
          membership.status in ["pending", "joined"]
      )
      |> lock("FOR UPDATE")
      |> Repo.all()
      |> Enum.map(&prepare_membership_for_fresh_connection/1)
    end)
  end

  def request(user, %ServerConnection{} = connection, channel) do
    request(user, connection, channel, MembershipLookup.casemapping(connection) || :ascii)
  end

  def request(
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
             case MembershipLookup.find_by_channel(active_connection, channel, casemapping) do
               %ChannelMembership{} = membership ->
                 attrs =
                   if membership.status == "joined" do
                     %{auto_join: true, left_at: nil, last_error: nil}
                   else
                     %{status: "pending", auto_join: true, left_at: nil, last_error: nil}
                   end

                 membership
                 |> ChannelMembership.changeset(attrs)
                 |> put_join_attempt(membership)
                 |> Repo.update!()

               nil ->
                 %ChannelMembership{user_id: user.id, server_connection_id: active_connection.id}
                 |> ChannelMembership.changeset(%{
                   channel: channel,
                   status: "pending",
                   auto_join: true
                 })
                 |> Ecto.Changeset.put_change(:join_attempt_id, Ecto.UUID.generate())
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

  def request(%User{}, %ServerConnection{}, _channel, _casemapping),
    do: {:error, :invalid_connection}

  defp assert_no_outer_transaction! do
    if Repo.in_transaction?() do
      raise ArgumentError, "cannot mutate channel memberships inside an existing transaction"
    end
  end

  defp put_join_attempt(changeset, %ChannelMembership{
         status: "pending",
         join_attempt_id: attempt_id
       })
       when is_binary(attempt_id),
       do: changeset

  defp put_join_attempt(changeset, %ChannelMembership{status: "joined"}), do: changeset

  defp put_join_attempt(changeset, %ChannelMembership{}),
    do: Ecto.Changeset.put_change(changeset, :join_attempt_id, Ecto.UUID.generate())

  defp prepare_membership_for_fresh_connection(%ChannelMembership{status: "joined"} = membership) do
    membership
    |> ChannelMembership.changeset(%{
      status: "pending",
      left_at: nil,
      last_error: nil
    })
    |> Ecto.Changeset.put_change(:join_attempt_id, Ecto.UUID.generate())
    |> Repo.update!()
  end

  defp prepare_membership_for_fresh_connection(%ChannelMembership{} = membership) do
    membership
    |> ChannelMembership.changeset(%{})
    |> put_join_attempt(membership)
    |> Repo.update!()
  end
end
