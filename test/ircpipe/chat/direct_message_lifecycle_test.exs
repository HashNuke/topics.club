defmodule Ircpipe.Chat.DirectMessageLifecycleTest do
  use Ircpipe.DataCase, async: true

  alias Ircpipe.Accounts.Scope
  alias Ircpipe.AccountsFixtures
  alias Ircpipe.Chat.{Connections, DirectMessageIngestion, DirectMessageLifecycle}

  test "owns direct-message thread opening, lookup, read state, and closing" do
    user = AccountsFixtures.user_fixture()
    scope = Scope.for_user(user)
    connection = connection_fixture(user)

    assert {:error, :invalid_nick} =
             DirectMessageLifecycle.open(user, connection, "not a nick")

    assert {:ok, thread} = DirectMessageLifecycle.open(user, connection, "mira")
    assert [listed] = DirectMessageLifecycle.list(user, connection)
    assert listed.id == thread.id
    assert DirectMessageLifecycle.get!(user, thread.id).server_connection.id == connection.id

    assert {:ok, read} =
             DirectMessageLifecycle.mark_read(scope, thread.id, thread.mutation_revision)

    assert read.unread_count == 0

    assert {:ok, closed} = DirectMessageLifecycle.close(scope, thread.id, read.mutation_revision)
    assert closed.closed_at
    assert DirectMessageLifecycle.list(user, connection) == []

    assert {:error, :direct_message_closed} =
             DirectMessageLifecycle.mark_read(scope, thread.id, closed.mutation_revision)
  end

  test "rejects read, block, and close mutations from a stale thread revision" do
    user = AccountsFixtures.user_fixture()
    scope = Scope.for_user(user)
    connection = connection_fixture(user)
    assert {:ok, opened} = DirectMessageLifecycle.open(user, connection, "mira")

    assert {:ok, %{thread: current}} =
             DirectMessageIngestion.record(
               connection,
               "mira",
               "mira",
               "newer message",
               "message",
               %{direction: "incoming"}
             )

    assert current.mutation_revision > opened.mutation_revision
    Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{user.id}")

    assert {:error, :stale_direct_message} =
             DirectMessageLifecycle.mark_read(scope, current.id, opened.mutation_revision)

    assert {:error, :stale_direct_message} =
             DirectMessageLifecycle.set_blocked(scope, current.id, true, opened.mutation_revision)

    assert {:error, :stale_direct_message} =
             DirectMessageLifecycle.close(scope, current.id, opened.mutation_revision)

    stored = DirectMessageLifecycle.get!(user, current.id)
    assert stored.mutation_revision == current.mutation_revision
    assert stored.unread_count == current.unread_count
    assert stored.blocked_at == nil
    assert stored.closed_at == nil
    refute_received {:direct_message_thread, _payload}
    refute_received {:direct_message_closed, _payload}
  end

  defp connection_fixture(user) do
    {:ok, connection} =
      Connections.create(user, %{
        "name" => "lifecycle-test",
        "host" => "irc.example.com",
        "nickname" => "mira"
      })

    connection
  end
end
