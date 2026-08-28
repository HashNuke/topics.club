defmodule TopicsClub.Chat.DirectMessageSenderTest do
  use TopicsClub.DataCase, async: true

  alias TopicsClub.AccountsFixtures

  alias TopicsClub.Chat.{
    Connections,
    DirectMessageLifecycle,
    DirectMessageSender,
    MessageHistory
  }

  test "transmits to the thread peer and persists the outgoing message" do
    user = AccountsFixtures.user_fixture()
    connection = connection_fixture(user)
    {:ok, thread} = DirectMessageLifecycle.open(user, connection, "akash")
    test_pid = self()

    assert {:ok, %{thread: sent_thread, message: message}} =
             DirectMessageSender.send(connection, thread.id, "hello privately", fn peer_nick ->
               send(test_pid, {:transmitted, peer_nick})
               :ok
             end)

    assert_receive {:transmitted, "akash"}
    assert sent_thread.id == thread.id
    assert message.body == "hello privately"
    assert message.nick == connection.nickname
    assert message.metadata["direction"] == "outgoing"
    assert message.metadata["target"] == "akash"

    assert Enum.map(MessageHistory.list_buffer_messages(user, "direct:#{thread.id}"), & &1.id) ==
             [
               message.id
             ]
  end

  test "does not transmit or persist for a closed thread" do
    user = AccountsFixtures.user_fixture()
    scope = AccountsFixtures.user_scope_fixture(user)
    connection = connection_fixture(user)
    {:ok, thread} = DirectMessageLifecycle.open(user, connection, "akash")

    {:ok, _closed} =
      DirectMessageLifecycle.close(scope, thread.id, thread.mutation_revision)

    test_pid = self()

    assert {:error, :direct_message_closed} =
             DirectMessageSender.send(connection, thread.id, "never sent", fn peer_nick ->
               send(test_pid, {:transmitted, peer_nick})
               :ok
             end)

    refute_received {:transmitted, _peer_nick}
    assert MessageHistory.list_buffer_messages(user, "direct:#{thread.id}") == []
  end

  test "rolls back persistence when transmission fails" do
    user = AccountsFixtures.user_fixture()
    connection = connection_fixture(user)
    {:ok, thread} = DirectMessageLifecycle.open(user, connection, "akash")

    assert {:error, :disconnected} =
             DirectMessageSender.send(connection, thread.id, "never stored", fn _peer_nick ->
               {:error, :disconnected}
             end)

    assert MessageHistory.list_buffer_messages(user, "direct:#{thread.id}") == []
  end

  test "rejects an outer transaction before transmitting or persisting" do
    user = AccountsFixtures.user_fixture()
    connection = connection_fixture(user)
    {:ok, thread} = DirectMessageLifecycle.open(user, connection, "akash")
    test_pid = self()

    assert {:error, :forced_rollback} =
             TopicsClub.Repo.transaction(fn ->
               assert_raise ArgumentError, ~r/cannot send inside an existing transaction/, fn ->
                 DirectMessageSender.send(connection, thread.id, "never sent", fn peer_nick ->
                   send(test_pid, {:transmitted, peer_nick})
                   :ok
                 end)
               end

               TopicsClub.Repo.rollback(:forced_rollback)
             end)

    refute_received {:transmitted, _peer_nick}
    assert MessageHistory.list_buffer_messages(user, "direct:#{thread.id}") == []
  end

  test "does not transmit after the connection is marked for deletion" do
    user = AccountsFixtures.user_fixture()
    connection = connection_fixture(user)
    {:ok, thread} = DirectMessageLifecycle.open(user, connection, "akash")
    test_pid = self()

    connection
    |> Ecto.Changeset.change(deleting: true)
    |> TopicsClub.Repo.update!()

    assert {:error, :connection_deleting} =
             DirectMessageSender.send(connection, thread.id, "never sent", fn peer_nick ->
               send(test_pid, {:transmitted, peer_nick})
               :ok
             end)

    refute_received {:transmitted, _peer_nick}
    assert MessageHistory.list_buffer_messages(user, "direct:#{thread.id}") == []
  end

  defp connection_fixture(user) do
    {:ok, connection} =
      Connections.create(user, %{
        "name" => "sender-test",
        "host" => "irc.example.com",
        "nickname" => "mira"
      })

    connection
  end
end
