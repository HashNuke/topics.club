defmodule Ircpipe.Chat.ConnectionSnapshotTest do
  use Ircpipe.DataCase, async: true

  alias Ircpipe.AccountsFixtures
  alias Ircpipe.Chat.ChannelMembership
  alias Ircpipe.Chat.ConnectionCasemapping
  alias Ircpipe.Chat.ConnectionSnapshot
  alias Ircpipe.Chat.Connections
  alias Ircpipe.Chat.DirectMessageLifecycle
  alias Ircpipe.Repo

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

  test "defers reconciliation broadcasts and rolls back changes with an outer transaction" do
    user = AccountsFixtures.user_fixture()

    assert {:ok, connection} =
             Connections.create(user, %{
               "name" => "rollback",
               "host" => "irc.rollback.test",
               "nickname" => "mira"
             })

    assert {:ok, connection} = ConnectionCasemapping.update(connection, :rfc1459)

    for channel <- ["#[ops]", "#" <> "{ops}"] do
      %ChannelMembership{user_id: user.id, server_connection_id: connection.id}
      |> ChannelMembership.changeset(%{channel: channel, status: "joined"})
      |> Repo.insert!()
    end

    Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{user.id}")
    connection_id = connection.id

    assert {:error, :forced_rollback} =
             Repo.transaction(fn ->
               snapshot = ConnectionSnapshot.capture_in_transaction(user)
               assert [{^connection_id, [_loser]}] = reconciliation_ids(snapshot.reconciliations)
               Repo.rollback(:forced_rollback)
             end)

    refute_receive {:buffer_left, _event}

    assert 2 ==
             ChannelMembership
             |> where([membership], membership.server_connection_id == ^connection.id)
             |> Repo.aggregate(:count)

    assert %{connections: [%{channel_memberships: [_survivor]}]} =
             ConnectionSnapshot.capture(user)

    assert_receive {:buffer_left, %{channel_membership_id: _loser_id}}

    assert 1 ==
             ChannelMembership
             |> where([membership], membership.server_connection_id == ^connection.id)
             |> Repo.aggregate(:count)
  end

  test "rejects transaction-owning snapshots and broadcasts inside an outer transaction" do
    user = AccountsFixtures.user_fixture()

    assert {:error, :forced_rollback} =
             Repo.transaction(fn ->
               assert_raise ArgumentError, ~r/use capture_in_transaction/, fn ->
                 ConnectionSnapshot.capture(user)
               end

               assert_raise ArgumentError, ~r/after the transaction commits/, fn ->
                 ConnectionSnapshot.broadcast_reconciliations([])
               end

               Repo.rollback(:forced_rollback)
             end)
  end

  defp reconciliation_ids(reconciliations) do
    Enum.map(reconciliations, fn {connection, losers} ->
      {connection.id, Enum.map(losers, & &1.id)}
    end)
  end
end
