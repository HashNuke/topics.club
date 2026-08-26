defmodule Ircpipe.Chat.DirectMessagesTest do
  use Ircpipe.DataCase, async: false

  alias Ircpipe.AccountsFixtures
  alias Ircpipe.Chat
  alias Ircpipe.Chat.Message

  setup do
    user = AccountsFixtures.user_fixture()
    scope = AccountsFixtures.user_scope_fixture(user)
    connection = connection_fixture(user, "z-oldest")

    %{user: user, scope: scope, connection: connection}
  end

  test "lists networks oldest first and preloads channels alphabetically", %{
    user: user,
    connection: oldest
  } do
    newest = connection_fixture(user, "alpha")

    {:ok, _zulu} = Chat.join_channel(user, oldest, "#zulu")
    {:ok, _alpha} = Chat.join_channel(user, oldest, "#alpha")

    connections = Chat.list_connections(user)

    assert Enum.map(connections, & &1.id) == [oldest.id, newest.id]

    assert Enum.map(List.first(connections).channel_memberships, & &1.channel) == [
             "#alpha",
             "#zulu"
           ]
  end

  test "lists open direct-message threads alphabetically", %{
    user: user,
    connection: connection
  } do
    assert {:ok, _thread} = Chat.open_direct_message(user, connection, "Zed")
    assert {:ok, _thread} = Chat.open_direct_message(user, connection, "akash")

    assert Enum.map(Chat.list_direct_message_threads(user, connection), & &1.peer_nick) == [
             "akash",
             "Zed"
           ]
  end

  test "persists outgoing messages in a durable thread and broadcasts its buffer", %{
    user: user,
    connection: connection
  } do
    Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{user.id}")

    assert {:ok, %{thread: thread, message: message, notify?: false}} =
             Chat.record_direct_message(
               connection,
               "akash",
               connection.nickname,
               "hello privately",
               "message",
               %{direction: "outgoing", target: "akash"}
             )

    assert thread.peer_nick == "akash"
    assert thread.unread_count == 0
    assert thread.closed_at == nil
    assert message.direct_message_thread_id == thread.id
    buffer_id = "direct:#{thread.id}"

    assert_receive {:direct_message_thread,
                    %{buffer: %{buffer_id: ^buffer_id, buffer_type: "direct_message"}}}

    assert_receive {:buffer_message, %{buffer_id: ^buffer_id, body: "hello privately"}}

    assert [%Message{id: message_id}] =
             Chat.list_buffer_messages(user, "direct:#{thread.id}")

    assert message_id == message.id
  end

  test "incoming messages reopen a thread, increment unread, and request attention", %{
    user: user,
    scope: scope,
    connection: connection
  } do
    Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{user.id}")
    assert {:ok, thread} = Chat.open_direct_message(user, connection, "akash")
    assert {:ok, _thread} = Chat.close_direct_message_thread(scope, thread.id)

    assert {:ok, %{thread: reopened, notify?: true}} =
             Chat.record_direct_message(
               connection,
               "akash",
               "akash",
               "ping",
               "message",
               %{
                 direction: "incoming",
                 account: "akash-account",
                 hostmask: "akash!user@example.test"
               }
             )

    assert reopened.id == thread.id
    assert reopened.closed_at == nil
    assert reopened.unread_count == 1
    assert reopened.identity_key == "account:akash-account"
    buffer_id = "direct:#{thread.id}"

    assert_receive {:direct_message_notification, %{buffer_id: ^buffer_id, body: "ping"}}

    assert {:ok, read} = Chat.mark_direct_message_read(scope, thread.id)
    assert read.unread_count == 0
  end

  test "blocking follows account identity across nick changes without attention spam", %{
    user: user,
    scope: scope,
    connection: connection
  } do
    Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{user.id}")

    assert {:ok, %{thread: thread}} =
             Chat.record_direct_message(
               connection,
               "akash",
               "akash",
               "first",
               "message",
               %{
                 direction: "incoming",
                 account: "akash-account",
                 hostmask: "akash!user@example.test"
               }
             )

    flush_mailbox()
    assert {:ok, blocked} = Chat.set_direct_message_blocked(scope, thread.id, true)
    assert blocked.blocked_at
    assert {:ok, _closed} = Chat.close_direct_message_thread(scope, thread.id)

    message_count = Repo.aggregate(Message, :count)

    assert {:ok, %{thread: renamed, message: nil, notify?: false, dropped?: true}} =
             Chat.record_direct_message(
               connection,
               "akash_",
               "akash_",
               "still here",
               "message",
               %{
                 direction: "incoming",
                 account: "akash-account",
                 hostmask: "akash_!user@example.test"
               }
             )

    assert renamed.id == thread.id
    assert renamed.peer_nick == "akash_"
    assert renamed.closed_at
    assert renamed.unread_count == 0
    assert Repo.aggregate(Message, :count) == message_count
    refute_receive {:direct_message_notification, _payload}

    assert {:ok, unblocked} = Chat.set_direct_message_blocked(scope, thread.id, false)
    refute unblocked.blocked_at
  end

  test "blocking falls back to user and host when IRC accounts are unavailable", %{
    user: user,
    scope: scope,
    connection: connection
  } do
    assert {:ok, %{thread: thread}} =
             Chat.record_direct_message(
               connection,
               "guest",
               "guest",
               "first",
               "message",
               %{direction: "incoming", hostmask: "guest!same-user@example.test"}
             )

    assert thread.identity_key == "hostmask:same-user@example.test"
    assert {:ok, _blocked} = Chat.set_direct_message_blocked(scope, thread.id, true)
    assert {:ok, _closed} = Chat.close_direct_message_thread(scope, thread.id)
    message_count = Repo.aggregate(Message, :count)

    assert {:ok, %{thread: same_thread, message: nil, dropped?: true}} =
             Chat.record_direct_message(
               connection,
               "renamed",
               "renamed",
               "should disappear",
               "message",
               %{direction: "incoming", hostmask: "renamed!same-user@example.test"}
             )

    assert same_thread.id == thread.id
    assert Repo.aggregate(Message, :count) == message_count
    assert Chat.list_direct_message_threads(user, connection) == []
  end

  defp connection_fixture(user, name) do
    {:ok, connection} =
      Chat.create_connection(user, %{
        "name" => "#{name}-#{System.unique_integer([:positive])}",
        "host" => "irc.example.test",
        "port" => 6697,
        "nickname" => "mira"
      })

    connection
  end

  defp flush_mailbox do
    receive do
      _message -> flush_mailbox()
    after
      0 -> :ok
    end
  end
end
