defmodule TopicsClub.Chat.ConnectionDeletionBatchStoreTest do
  use TopicsClub.DataCase, async: true

  alias TopicsClub.AccountsFixtures
  alias TopicsClub.Chat

  alias TopicsClub.Chat.{
    ConnectionDeletionBatchStore,
    ConnectionDeletionEventBatch,
    Connections
  }

  alias TopicsClub.Repo

  test "persists deterministic channel and server deletion events inside the owner transaction" do
    user = AccountsFixtures.user_fixture()

    assert {:ok, connection} =
             Connections.create(user, %{
               "name" => "event batch",
               "host" => "irc.event-batch.test",
               "nickname" => "mira"
             })

    assert {:ok, first_membership} = Chat.join_channel(user, connection, "#first")
    assert {:ok, second_membership} = Chat.join_channel(user, connection, "#second")
    connection = Repo.preload(connection, :channel_memberships, force: true)

    assert_raise ArgumentError, ~r/transaction/, fn ->
      ConnectionDeletionBatchStore.insert!(connection)
    end

    assert {:ok, batch_id} =
             Repo.transaction(fn ->
               ConnectionDeletionBatchStore.insert!(connection).id
             end)

    batch = Repo.get!(ConnectionDeletionEventBatch, batch_id)

    assert batch.user_id == user.id
    assert batch.server_connection_id == connection.id

    assert [first_event, second_event, server_event] = batch.payloads["events"]

    assert first_event == %{
             "buffer_id" => "channel:#{first_membership.id}",
             "channel_membership_id" => first_membership.id,
             "event_id" => "connection_deletion:#{connection.id}:channel:#{first_membership.id}",
             "occurred_at" => first_event["occurred_at"],
             "server_connection_id" => connection.id
           }

    assert second_event == %{
             "buffer_id" => "channel:#{second_membership.id}",
             "channel_membership_id" => second_membership.id,
             "event_id" => "connection_deletion:#{connection.id}:channel:#{second_membership.id}",
             "occurred_at" => first_event["occurred_at"],
             "server_connection_id" => connection.id
           }

    assert server_event == %{
             "buffer_id" => "server:#{connection.id}",
             "channel_membership_id" => nil,
             "event_id" => "connection_deletion:#{connection.id}:server:#{connection.id}",
             "occurred_at" => first_event["occurred_at"],
             "server_connection_id" => connection.id
           }

    assert {:ok, _occurred_at, 0} = DateTime.from_iso8601(first_event["occurred_at"])
  end
end
