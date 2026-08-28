defmodule TopicsClub.Chat.ChannelJoinRequest do
  @moduledoc false

  alias TopicsClub.Accounts.User

  alias TopicsClub.Chat.{
    ChannelMembership,
    MembershipLookup,
    MembershipReconciler,
    ServerConnection,
    ServerConnectionLock
  }

  alias TopicsClub.Repo

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

  def request(%User{}, %ServerConnection{}, _channel, _casemapping),
    do: {:error, :invalid_connection}

  defp assert_no_outer_transaction! do
    if Repo.in_transaction?() do
      raise ArgumentError, "cannot mutate channel memberships inside an existing transaction"
    end
  end
end
