defmodule TopicsClub.Chat.ConnectionSnapshotTest do
  use TopicsClubWeb.DataCase, async: true

  alias TopicsClub.AccountsFixtures
  alias TopicsClub.Chat.ChannelMembership
  alias TopicsClub.Chat.ConnectionSnapshot
  alias TopicsClub.Chat.Connections
  alias TopicsClub.Chat.DirectMessageLifecycle
  alias TopicsClub.Repo

  test "captures open direct messages with closed-thread tombstones" do
    user = AccountsFixtures.user_fixture()
    scope = AccountsFixtures.user_scope_fixture(user)

    assert {:ok, connection} =
             Connections.create(user, %{
               "name" => "direct messages",
               "host" => "irc.direct.test",
               "nickname" => "mira"
             })

    assert {:ok, open_thread} = DirectMessageLifecycle.open(user, connection, "Zed")
    assert {:ok, closed_thread} = DirectMessageLifecycle.open(user, connection, "akash")

    assert {:ok, closed_thread} =
             DirectMessageLifecycle.close(
               scope,
               closed_thread.id,
               closed_thread.mutation_revision
             )

    assert %{
             connections: [loaded],
             direct_message_tombstones: [tombstone]
           } = ConnectionSnapshot.capture(user)

    assert Enum.map(loaded.direct_message_threads, & &1.id) == [open_thread.id]

    assert tombstone == %{
             buffer_id: "direct:#{closed_thread.id}",
             server_connection_id: connection.id,
             direct_message_thread_id: closed_thread.id,
             revision: closed_thread.mutation_revision
           }
  end

  test "captures memberships without reconciling or broadcasting engine effects" do
    user = AccountsFixtures.user_fixture()

    assert {:ok, connection} =
             Connections.create(user, %{
               "name" => "rollback",
               "host" => "irc.rollback.test",
               "nickname" => "mira"
             })

    connection =
      connection
      |> Ecto.Changeset.change(casemapping: "rfc1459")
      |> Repo.update!()

    for channel <- ["#[ops]", "#" <> "{ops}"] do
      %ChannelMembership{user_id: user.id, server_connection_id: connection.id}
      |> ChannelMembership.changeset(%{channel: channel, status: "joined"})
      |> Repo.insert!()
    end

    Phoenix.PubSub.subscribe(TopicsClub.PubSub, "user:#{user.id}")

    assert {:ok, %{connections: [%{channel_memberships: memberships}]}} =
             Repo.transaction(fn -> ConnectionSnapshot.capture_in_transaction(user) end)

    assert length(memberships) == 2

    refute_receive {:buffer_left, _event}

    assert 2 ==
             ChannelMembership
             |> where([membership], membership.server_connection_id == ^connection.id)
             |> Repo.aggregate(:count)

    assert %{connections: [%{channel_memberships: persisted_memberships}]} =
             ConnectionSnapshot.capture(user)

    assert length(persisted_memberships) == 2
    refute_receive {:buffer_left, _event}
  end

  test "rejects a transaction-owning snapshot inside an outer transaction" do
    user = AccountsFixtures.user_fixture()

    assert {:error, :forced_rollback} =
             Repo.transaction(fn ->
               assert_raise ArgumentError, ~r/use capture_in_transaction/, fn ->
                 ConnectionSnapshot.capture(user)
               end

               Repo.rollback(:forced_rollback)
             end)
  end
end
