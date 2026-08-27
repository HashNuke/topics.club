defmodule Ircpipe.Chat.DirectMessagesTest do
  use Ircpipe.DataCase, async: false

  alias Ircpipe.AccountsFixtures
  alias Ircpipe.Chat
  alias Ircpipe.Chat.Connections
  alias Ircpipe.Chat.DirectMessageIngestion
  alias Ircpipe.Chat.DirectMessageLifecycle
  alias Ircpipe.Chat.DirectMessageRenamer
  alias Ircpipe.Chat.DirectMessageSender
  alias Ircpipe.Chat.MessageIngestion
  alias Ircpipe.Chat.{DirectMessageBlockIdentity, Message, MessageHistory, Notification}
  alias Ircpipe.Irc.Identifier
  alias Ircpipe.Notifications.Delivery

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

    connections = Connections.list(user)

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
    assert {:ok, _thread} = DirectMessageLifecycle.open(user, connection, "Zed")
    assert {:ok, _thread} = DirectMessageLifecycle.open(user, connection, "akash")

    assert Enum.map(DirectMessageLifecycle.list(user, connection), & &1.peer_nick) == [
             "akash",
             "Zed"
           ]
  end

  test "rejects direct-message mutations after connection deletion is marked", %{
    user: user,
    scope: scope,
    connection: connection
  } do
    assert {:ok, thread} = DirectMessageLifecycle.open(user, connection, "akash")
    Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{user.id}")

    connection
    |> Ecto.Changeset.change(deleting: true)
    |> Repo.update!()

    assert {:error, :connection_deleting} =
             DirectMessageLifecycle.open(user, connection, "other")

    assert {:error, :connection_deleting} = DirectMessageLifecycle.close(scope, thread.id)

    assert {:error, :connection_deleting} =
             DirectMessageLifecycle.set_blocked(scope, thread.id, true)

    assert {:error, :connection_deleting} = DirectMessageLifecycle.mark_read(scope, thread.id)

    stored = DirectMessageLifecycle.get!(user, thread.id)
    assert stored.closed_at == nil
    assert stored.blocked_at == nil
    assert stored.mutation_revision == thread.mutation_revision
    refute_received {:direct_message_thread, _payload}
    refute_received {:direct_message_closed, _payload}
  end

  test "rejects direct-message mutations inside an outer transaction", %{
    user: user,
    scope: scope,
    connection: connection
  } do
    assert {:ok, thread} = DirectMessageLifecycle.open(user, connection, "akash")
    Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{user.id}")

    assert {:error, :forced_rollback} =
             Repo.transaction(fn ->
               mutations = [
                 fn -> DirectMessageLifecycle.open(user, connection, "other") end,
                 fn -> DirectMessageLifecycle.close(scope, thread.id) end,
                 fn -> DirectMessageLifecycle.set_blocked(scope, thread.id, true) end,
                 fn -> DirectMessageLifecycle.mark_read(scope, thread.id) end
               ]

               Enum.each(mutations, fn mutation ->
                 assert_raise ArgumentError,
                              ~r/cannot mutate direct messages inside an existing transaction/,
                              mutation
               end)

               Repo.rollback(:forced_rollback)
             end)

    stored = DirectMessageLifecycle.get!(user, thread.id)
    assert stored.closed_at == nil
    assert stored.blocked_at == nil
    assert stored.mutation_revision == thread.mutation_revision
    refute_received {:direct_message_thread, _payload}
    refute_received {:direct_message_closed, _payload}
  end

  test "completed deletion between a DM commit and effects drops publication without raising", %{
    user: user,
    scope: scope,
    connection: connection
  } do
    assert {:ok, thread} = DirectMessageLifecycle.open(user, connection, "akash")
    Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{user.id}")
    flush_mailbox()

    effects_ref = make_ref()
    previous_barrier = Application.get_env(:ircpipe, :connection_effects_before_lock_barrier)

    Application.put_env(
      :ircpipe,
      :connection_effects_before_lock_barrier,
      {self(), effects_ref}
    )

    on_exit(fn ->
      restore_env(:connection_effects_before_lock_barrier, previous_barrier)
    end)

    supervisor = start_supervised!(Task.Supervisor)

    read =
      Task.Supervisor.async_nolink(supervisor, fn ->
        DirectMessageLifecycle.mark_read(scope, thread.id)
      end)

    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), read.pid)

    assert_receive {:connection_effects_paused, effects_pid, ^effects_ref, connection_id}, 5_000
    assert connection_id == connection.id
    assert {:ok, deleted} = Connections.delete(user, connection.id)
    assert deleted.id == connection.id

    send(effects_pid, {:continue_connection_effects, effects_ref})
    assert {:ok, _updated} = Task.await(read, 5_000)

    refute_received {:direct_message_thread, _payload}
    refute_received {:direct_message_closed, _payload}
  end

  test "persists outgoing messages in a durable thread and broadcasts its buffer", %{
    user: user,
    connection: connection
  } do
    Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{user.id}")

    assert {:ok, %{thread: thread, message: message, notify?: false}} =
             DirectMessageIngestion.record(
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
             MessageHistory.list_buffer_messages(user, "direct:#{thread.id}")

    assert message_id == message.id
  end

  test "incoming messages reopen a thread, increment unread, and request attention", %{
    user: user,
    scope: scope,
    connection: connection
  } do
    Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{user.id}")
    assert {:ok, thread} = DirectMessageLifecycle.open(user, connection, "akash")
    assert {:ok, _thread} = DirectMessageLifecycle.close(scope, thread.id)

    assert {:ok, %{thread: reopened, message: message, notify?: true}} =
             DirectMessageIngestion.record(
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
    notification = Repo.get_by!(Notification, message_id: message.id)
    assert notification.direct_message_thread_id == thread.id

    assert {:ok, read} = DirectMessageLifecycle.mark_read(scope, thread.id)
    assert read.unread_count == 0
  end

  test "a delayed close effect serializes a newer reopen", %{
    user: user,
    scope: scope,
    connection: connection
  } do
    Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{user.id}")
    assert {:ok, thread} = DirectMessageLifecycle.open(user, connection, "akash")
    assert thread.mutation_revision == 1

    previous_pause = Application.get_env(:ircpipe, :pause_direct_message_closed_broadcast)

    on_exit(fn ->
      if is_nil(previous_pause) do
        Application.delete_env(:ircpipe, :pause_direct_message_closed_broadcast)
      else
        Application.put_env(:ircpipe, :pause_direct_message_closed_broadcast, previous_pause)
      end
    end)

    Application.put_env(:ircpipe, :pause_direct_message_closed_broadcast, {self(), 2})
    supervisor = start_supervised!(Task.Supervisor)

    close =
      Task.Supervisor.async_nolink(supervisor, fn ->
        receive do
          :close_thread -> DirectMessageLifecycle.close(scope, thread.id)
        end
      end)

    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), close.pid)
    send(close.pid, :close_thread)

    assert_receive {:direct_message_closed_broadcast_paused, close_pid, thread_id, 2}
    assert thread_id == thread.id

    reopen =
      Task.Supervisor.async_nolink(supervisor, fn ->
        DirectMessageIngestion.record(
          connection,
          "akash",
          "akash",
          "newer message",
          "message",
          %{direction: "incoming", account: "akash-account"}
        )
      end)

    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), reopen.pid)
    refute Task.yield(reopen, 100)

    send(close_pid, {:continue_direct_message_closed_broadcast, 2})
    assert {:ok, closed} = Task.await(close)
    assert closed.mutation_revision == 2

    buffer_id = "direct:#{thread.id}"
    assert_receive {:direct_message_closed, %{buffer_id: ^buffer_id, revision: 2}}

    assert {:ok, %{thread: reopened}} = Task.await(reopen)
    assert reopened.closed_at == nil
    assert reopened.mutation_revision == 4

    assert_receive {:direct_message_thread, %{buffer: %{buffer_id: ^buffer_id}, revision: 4}}

    stored = DirectMessageLifecycle.get!(user, thread.id)
    assert stored.closed_at == nil
    assert stored.mutation_revision == 4
  end

  test "a delayed block effect serializes a newer read", %{
    user: user,
    scope: scope,
    connection: connection
  } do
    Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{user.id}")
    assert {:ok, thread} = DirectMessageLifecycle.open(user, connection, "akash")
    assert thread.mutation_revision == 1

    previous_pause = Application.get_env(:ircpipe, :pause_direct_message_thread_broadcast)

    on_exit(fn ->
      if is_nil(previous_pause) do
        Application.delete_env(:ircpipe, :pause_direct_message_thread_broadcast)
      else
        Application.put_env(:ircpipe, :pause_direct_message_thread_broadcast, previous_pause)
      end
    end)

    Application.put_env(:ircpipe, :pause_direct_message_thread_broadcast, {self(), 2})
    supervisor = start_supervised!(Task.Supervisor)

    block =
      Task.Supervisor.async_nolink(supervisor, fn ->
        receive do
          :block_thread -> DirectMessageLifecycle.set_blocked(scope, thread.id, true)
        end
      end)

    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), block.pid)
    send(block.pid, :block_thread)

    assert_receive {:direct_message_thread_broadcast_paused, block_pid, thread_id, 2}
    assert thread_id == thread.id

    read =
      Task.Supervisor.async_nolink(supervisor, fn ->
        DirectMessageLifecycle.mark_read(scope, thread.id)
      end)

    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), read.pid)
    refute Task.yield(read, 100)

    send(block_pid, {:continue_direct_message_thread_broadcast, 2})
    assert {:ok, blocked} = Task.await(block)
    assert blocked.mutation_revision == 2

    buffer_id = "direct:#{thread.id}"

    assert_receive {:direct_message_thread,
                    %{buffer: %{buffer_id: ^buffer_id, blocked: true}, revision: 2}}

    assert {:ok, read_thread} = Task.await(read)
    assert read_thread.mutation_revision == 3
    assert read_thread.blocked_at

    assert_receive {:direct_message_thread,
                    %{buffer: %{buffer_id: ^buffer_id, blocked: true}, revision: 3}}
  end

  test "reads reject closed threads without advancing their revision", %{
    user: user,
    scope: scope,
    connection: connection
  } do
    assert {:ok, thread} = DirectMessageLifecycle.open(user, connection, "akash")
    assert {:ok, closed} = DirectMessageLifecycle.close(scope, thread.id)

    assert {:error, :direct_message_closed} = DirectMessageLifecycle.mark_read(scope, thread.id)

    stored = DirectMessageLifecycle.get!(user, thread.id)
    assert stored.closed_at
    assert stored.mutation_revision == closed.mutation_revision
  end

  test "blocking follows account identity across nick changes without attention spam", %{
    user: user,
    scope: scope,
    connection: connection
  } do
    Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{user.id}")

    assert {:ok, %{thread: thread}} =
             DirectMessageIngestion.record(
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
    assert {:ok, blocked} = DirectMessageLifecycle.set_blocked(scope, thread.id, true)
    assert blocked.blocked_at

    assert DirectMessageBlockIdentity
           |> where([identity], identity.direct_message_thread_id == ^thread.id)
           |> select([identity], identity.identity_key)
           |> Repo.all()
           |> Enum.sort() == ["account:akash-account", "hostmask:user@example.test"]

    assert {:ok, _closed} = DirectMessageLifecycle.close(scope, thread.id)

    message_count = Repo.aggregate(Message, :count)

    assert {:ok, %{thread: renamed, message: nil, notify?: false, dropped?: true}} =
             DirectMessageIngestion.record(
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
    assert renamed.peer_nick == "akash"
    assert renamed.closed_at
    assert renamed.unread_count == 0
    assert Repo.aggregate(Message, :count) == message_count
    assert {:ok, unblocked} = DirectMessageLifecycle.set_blocked(scope, thread.id, false)
    refute unblocked.blocked_at
  end

  test "blocking falls back to user and host when IRC accounts are unavailable", %{
    user: user,
    scope: scope,
    connection: connection
  } do
    assert {:ok, %{thread: thread}} =
             DirectMessageIngestion.record(
               connection,
               "guest",
               "guest",
               "first",
               "message",
               %{direction: "incoming", hostmask: "guest!same-user@example.test"}
             )

    assert thread.identity_key == "hostmask:same-user@example.test"
    assert {:ok, _blocked} = DirectMessageLifecycle.set_blocked(scope, thread.id, true)
    assert {:ok, _closed} = DirectMessageLifecycle.close(scope, thread.id)
    message_count = Repo.aggregate(Message, :count)

    assert {:ok, %{thread: same_thread, message: nil, dropped?: true}} =
             DirectMessageIngestion.record(
               connection,
               "renamed",
               "renamed",
               "should disappear",
               "message",
               %{direction: "incoming", hostmask: "renamed!same-user@example.test"}
             )

    assert same_thread.id == thread.id
    assert Repo.aggregate(Message, :count) == message_count
    assert DirectMessageLifecycle.list(user, connection) == []
  end

  test "a different account reusing a blocked nick gets an independent thread", %{
    user: user,
    scope: scope,
    connection: connection
  } do
    assert {:ok, %{thread: blocked_thread}} =
             DirectMessageIngestion.record(
               connection,
               "guest",
               "guest",
               "first",
               "message",
               %{
                 direction: "incoming",
                 account: "first-account",
                 hostmask: "guest!first@example.test"
               }
             )

    assert {:ok, _blocked} = DirectMessageLifecycle.set_blocked(scope, blocked_thread.id, true)

    assert {:ok, %{thread: new_thread, message: message, dropped?: false}} =
             DirectMessageIngestion.record(
               connection,
               "guest",
               "guest",
               "I am somebody else",
               "message",
               %{
                 direction: "incoming",
                 account: "second-account",
                 hostmask: "guest!second@example.test"
               }
             )

    refute new_thread.id == blocked_thread.id
    assert message.body == "I am somebody else"
    assert is_nil(new_thread.blocked_at)
    assert DirectMessageLifecycle.get!(user, blocked_thread.id).blocked_at
  end

  test "an account appearing later preserves a user-at-host thread", %{
    connection: connection
  } do
    assert {:ok, %{thread: original}} =
             DirectMessageIngestion.record(
               connection,
               "guest",
               "guest",
               "first",
               "message",
               %{direction: "incoming", hostmask: "guest!same-user@example.test"}
             )

    assert {:ok, %{thread: identified}} =
             DirectMessageIngestion.record(
               connection,
               "renamed",
               "renamed",
               "second",
               "message",
               %{
                 direction: "incoming",
                 account: "known-account",
                 hostmask: "renamed!same-user@example.test"
               }
             )

    assert identified.id == original.id
    assert identified.peer_nick == "renamed"
  end

  test "an identified peer can adopt a departed peer's nick without a unique-key crash", %{
    user: user,
    connection: connection
  } do
    Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{user.id}")

    assert {:ok, %{thread: account_a}} =
             DirectMessageIngestion.record(
               connection,
               "alpha",
               "alpha",
               "from A",
               "message",
               %{direction: "incoming", account: "account-a", hostmask: "alpha!a@example.test"}
             )

    assert {:ok, %{thread: account_b}} =
             DirectMessageIngestion.record(
               connection,
               "beta",
               "beta",
               "from B",
               "message",
               %{direction: "incoming", account: "account-b", hostmask: "beta!b@example.test"}
             )

    delayed_notification =
      Repo.get_by!(Notification, direct_message_thread_id: account_b.id)

    flush_mailbox()

    assert {:ok, renamed} =
             DirectMessageRenamer.rename(
               connection,
               "alpha",
               "beta",
               %{account: "account-a", hostmask: "beta!a@example.test"},
               :rfc1459
             )

    assert renamed.id == account_a.id
    assert renamed.peer_nick == "beta"
    displaced_buffer_id = "direct:#{account_b.id}"

    assert_receive {:direct_message_closed, %{buffer_id: ^displaced_buffer_id}}

    displaced = DirectMessageLifecycle.get!(user, account_b.id)
    assert displaced.closed_at
    assert displaced.last_read_at
    assert displaced.unread_count == 0
    assert String.starts_with?(displaced.peer_key, "archived:")
    assert Repo.get!(Notification, delayed_notification.id).read_at

    assert {:cancel, :notification_not_found} =
             Delivery.deliver(delayed_notification.id)

    assert {:ok, %{thread: same_a, message: message}} =
             DirectMessageIngestion.record(
               connection,
               "beta",
               "beta",
               "A after rename",
               "message",
               %{direction: "incoming", account: "account-a", hostmask: "beta!a@example.test"}
             )

    assert same_a.id == account_a.id
    assert message.body == "A after rename"
  end

  test "server history never includes direct-message rows", %{
    user: user,
    connection: connection
  } do
    MessageIngestion.record_server(connection, "server line")

    assert {:ok, %{message: direct_message}} =
             DirectMessageIngestion.record(
               connection,
               "akash",
               connection.nickname,
               "private line",
               "command",
               %{
                 direction: "outgoing",
                 command_id: "private-command",
                 command_status: "sent"
               }
             )

    assert Enum.map(
             MessageHistory.list_buffer_messages(user, "server:#{connection.id}"),
             & &1.body
           ) == [
             "server line"
           ]

    refute direct_message.id in Enum.map(
             MessageHistory.list_buffer_command_messages(user, "server:#{connection.id}", [
               "private-command"
             ]),
             & &1.id
           )
  end

  test "an ingestion waiting behind a block transaction is dropped before persistence" do
    test_pid = self()
    supervisor = start_supervised!(Task.Supervisor)
    pause_ref = make_ref()
    previous_pause = Application.get_env(:ircpipe, :pause_direct_message_block_after_lock)

    Application.put_env(
      :ircpipe,
      :pause_direct_message_block_after_lock,
      {test_pid, pause_ref}
    )

    {user, scope, connection, thread} =
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        user = AccountsFixtures.user_fixture()
        scope = AccountsFixtures.user_scope_fixture(user)
        connection = connection_fixture(user, "concurrent-block")

        {:ok, %{thread: thread}} =
          DirectMessageIngestion.record(
            connection,
            "guest",
            "guest",
            "first",
            "message",
            %{
              direction: "incoming",
              account: "stable-account",
              hostmask: "guest!stable@example.test"
            }
          )

        {user, scope, connection, thread}
      end)

    on_exit(fn ->
      restore_env(:pause_direct_message_block_after_lock, previous_pause)

      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        if persisted_user = Repo.get(Ircpipe.Accounts.User, user.id),
          do: Repo.delete!(persisted_user)
      end)
    end)

    blocker =
      Task.Supervisor.async_nolink(supervisor, fn ->
        Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
          DirectMessageLifecycle.set_blocked(scope, thread.id, true)
        end)
      end)

    assert_receive {:direct_message_block_paused, blocker_pid, ^pause_ref, thread_id}
    assert thread_id == thread.id

    ingestion =
      Task.Supervisor.async_nolink(supervisor, fn ->
        send(test_pid, :ingestion_started)

        Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
          DirectMessageIngestion.record(
            connection,
            "renamed",
            "renamed",
            "must never persist",
            "message",
            %{
              direction: "incoming",
              account: "stable-account",
              hostmask: "renamed!stable@example.test"
            }
          )
        end)
      end)

    assert_receive :ingestion_started
    refute Task.yield(ingestion, 100)
    send(blocker_pid, {:continue_direct_message_block, pause_ref})

    assert {:ok, _blocked} = Task.await(blocker)
    assert {:ok, %{message: nil, dropped?: true}} = Task.await(ingestion)

    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      refute Repo.exists?(from(message in Message, where: message.body == "must never persist"))
    end)
  end

  test "closing a direct message waits for an in-flight send to transmit and persist" do
    test_pid = self()
    supervisor = start_supervised!(Task.Supervisor)

    {user, scope, connection, thread} =
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        user = AccountsFixtures.user_fixture()
        scope = AccountsFixtures.user_scope_fixture(user)
        connection = connection_fixture(user, "concurrent-send-close")
        {:ok, thread} = DirectMessageLifecycle.open(user, connection, "guest")
        {user, scope, connection, thread}
      end)

    Application.put_env(:ircpipe, :pause_direct_message_send, test_pid)

    on_exit(fn ->
      Application.delete_env(:ircpipe, :pause_direct_message_send)

      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        if persisted_user = Repo.get(Ircpipe.Accounts.User, user.id),
          do: Repo.delete!(persisted_user)
      end)
    end)

    sender =
      Task.Supervisor.async_nolink(supervisor, fn ->
        Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
          DirectMessageSender.send(connection, thread.id, "serialized hello", fn target ->
            send(test_pid, {:direct_message_transmitted, target})
            :ok
          end)
        end)
      end)

    assert_receive {:direct_message_transmitted, "guest"}
    assert_receive {:direct_message_send_paused, sender_pid, thread_id}
    assert thread_id == thread.id

    closer =
      Task.Supervisor.async_nolink(supervisor, fn ->
        send(test_pid, :direct_message_close_started)

        Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
          DirectMessageLifecycle.close(scope, thread.id)
        end)
      end)

    assert_receive :direct_message_close_started
    refute Task.yield(closer, 100)

    send(sender_pid, {:continue_direct_message_send, thread.id})
    assert {:ok, %{message: sent_message, thread: sent_thread}} = Task.await(sender)
    assert sent_thread.id == thread.id
    assert sent_message.body == "serialized hello"
    assert {:ok, closed_thread} = Task.await(closer)
    assert closed_thread.id == thread.id
    assert closed_thread.closed_at

    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      persisted = DirectMessageLifecycle.get!(user, thread.id)
      assert persisted.closed_at

      assert Repo.exists?(
               from(message in Message,
                 where:
                   message.direct_message_thread_id == ^thread.id and
                     message.body == "serialized hello"
               )
             )
    end)
  end

  test "a block waiting behind peer displacement cannot resurrect the archived thread" do
    test_pid = self()
    supervisor = start_supervised!(Task.Supervisor)
    pause_ref = make_ref()
    previous_pause = Application.get_env(:ircpipe, :pause_direct_message_rename_after_lock)

    Application.put_env(
      :ircpipe,
      :pause_direct_message_rename_after_lock,
      {test_pid, pause_ref}
    )

    {user, scope, connection, account_a, account_b} =
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        user = AccountsFixtures.user_fixture()
        scope = AccountsFixtures.user_scope_fixture(user)
        connection = connection_fixture(user, "concurrent-displacement")

        {:ok, %{thread: account_a}} =
          DirectMessageIngestion.record(
            connection,
            "alpha",
            "alpha",
            "from A",
            "message",
            %{direction: "incoming", account: "account-a", hostmask: "alpha!a@example.test"}
          )

        {:ok, %{thread: account_b}} =
          DirectMessageIngestion.record(
            connection,
            "beta",
            "beta",
            "from B",
            "message",
            %{direction: "incoming", account: "account-b", hostmask: "beta!b@example.test"}
          )

        {user, scope, connection, account_a, account_b}
      end)

    on_exit(fn ->
      restore_env(:pause_direct_message_rename_after_lock, previous_pause)

      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        if persisted_user = Repo.get(Ircpipe.Accounts.User, user.id),
          do: Repo.delete!(persisted_user)
      end)
    end)

    Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{user.id}")

    displacement =
      Task.Supervisor.async_nolink(supervisor, fn ->
        Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
          DirectMessageRenamer.rename(
            connection,
            account_a.peer_nick,
            account_b.peer_nick,
            %{account: "account-a", hostmask: "beta!a@example.test"},
            :rfc1459
          )
        end)
      end)

    assert_receive {:direct_message_rename_paused, displacement_pid, ^pause_ref, connection_id}
    assert connection_id == connection.id

    blocker =
      Task.Supervisor.async_nolink(supervisor, fn ->
        send(test_pid, :blocking_started)

        Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
          DirectMessageLifecycle.set_blocked(scope, account_b.id, true)
        end)
      end)

    assert_receive :blocking_started
    refute Task.yield(blocker, 100)
    send(displacement_pid, {:continue_direct_message_rename, pause_ref})

    assert {:ok, renamed} = Task.await(displacement)
    assert renamed.id == account_a.id
    assert {:error, :direct_message_closed} = Task.await(blocker)

    archived =
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        DirectMessageLifecycle.get!(user, account_b.id)
      end)

    assert archived.closed_at
    assert String.starts_with?(archived.peer_key, "archived:")
    refute archived.blocked_at

    archived_buffer_id = "direct:#{account_b.id}"
    assert_receive {:direct_message_closed, %{buffer_id: ^archived_buffer_id}}

    refute_receive {:direct_message_thread,
                    %{buffer: %{buffer_id: ^archived_buffer_id, blocked: true}}}
  end

  test "valid nick targets honor IRC special characters and negotiated NICKLEN" do
    assert Identifier.valid_nick?("pipe|nick", %{"NICKLEN" => "30"})
    assert Identifier.valid_nick?(String.duplicate("a", 30), %{"NICKLEN" => "30"})
    refute Identifier.valid_nick?(String.duplicate("a", 31), %{"NICKLEN" => "30"})
    refute Identifier.valid_nick?("#channel", %{"NICKLEN" => "30"})
  end

  defp connection_fixture(user, name) do
    {:ok, connection} =
      Connections.create(user, %{
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

  defp restore_env(key, nil), do: Application.delete_env(:ircpipe, key)
  defp restore_env(key, value), do: Application.put_env(:ircpipe, key, value)
end
