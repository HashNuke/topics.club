defmodule Ircpipe.Chat.ReadStateTest do
  use Ircpipe.DataCase, async: false

  alias Ircpipe.AccountsFixtures

  alias Ircpipe.Chat.{
    Connections,
    MessageIngestion,
    Notification,
    ReadState
  }

  alias Ircpipe.Repo

  test "marks owned channel and server buffers read" do
    user = AccountsFixtures.user_fixture()
    connection = connection_fixture(user)
    {:ok, membership} = Ircpipe.Chat.join_channel(user, connection, "#elixir")

    {:ok, message} =
      MessageIngestion.record_channel(connection, membership.channel, "akash", "mira: ping")

    notification = Repo.get_by!(Notification, message_id: message.id)

    assert :ok = ReadState.mark(user, Repo.reload!(membership))
    persisted_membership = Repo.reload!(membership)
    assert persisted_membership.unread_count == 0
    assert persisted_membership.mention_count == 0
    assert persisted_membership.last_read_at
    assert Repo.reload!(notification).read_at

    MessageIngestion.record_server(connection, "Connected")
    assert :ok = ReadState.mark(user, Repo.reload!(connection))
    persisted_connection = Repo.reload!(connection)
    assert persisted_connection.unread_count == 0
    assert persisted_connection.last_read_at
  end

  test "a delayed message publication cannot restore counters after a newer read" do
    supervisor = start_supervised!(Task.Supervisor)
    user = AccountsFixtures.user_fixture()
    connection = connection_fixture(user)
    {:ok, membership} = Ircpipe.Chat.join_channel(user, connection, "#elixir")
    Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{user.id}")

    effects_ref = make_ref()
    previous_barrier = Application.get_env(:ircpipe_core, :connection_effects_before_lock_barrier)

    Application.put_env(
      :ircpipe_core,
      :connection_effects_before_lock_barrier,
      {self(), effects_ref}
    )

    on_exit(fn ->
      restore_env(:connection_effects_before_lock_barrier, previous_barrier)
    end)

    ingestion =
      Task.Supervisor.async_nolink(supervisor, fn ->
        MessageIngestion.record_channel(connection, membership.channel, "akash", "mira: ping")
      end)

    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), ingestion.pid)

    assert_receive {:connection_effects_paused, effects_pid, ^effects_ref, connection_id}, 5_000
    assert connection_id == connection.id
    assert Repo.reload!(membership).unread_count == 1

    Application.delete_env(:ircpipe_core, :connection_effects_before_lock_barrier)
    assert :ok = ReadState.mark(user, Repo.reload!(membership))
    assert_receive {:buffer_read, %{unread_count: 0, mention_count: 0}}

    send(effects_pid, {:continue_connection_effects, effects_ref})
    assert {:ok, _message} = Task.await(ingestion, 5_000)
    assert_receive {:buffer_message, %{unread_count: 0, mention_count: 0}}
  end

  test "a delayed read publication cannot clear counters from a newer message" do
    supervisor = start_supervised!(Task.Supervisor)
    user = AccountsFixtures.user_fixture()
    connection = connection_fixture(user)
    {:ok, membership} = Ircpipe.Chat.join_channel(user, connection, "#elixir")

    {:ok, _message} =
      MessageIngestion.record_channel(connection, membership.channel, "akash", "first")

    Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{user.id}")

    effects_ref = make_ref()
    previous_barrier = Application.get_env(:ircpipe_core, :connection_effects_before_lock_barrier)

    Application.put_env(
      :ircpipe_core,
      :connection_effects_before_lock_barrier,
      {self(), effects_ref}
    )

    on_exit(fn ->
      restore_env(:connection_effects_before_lock_barrier, previous_barrier)
    end)

    read =
      Task.Supervisor.async_nolink(supervisor, fn ->
        ReadState.mark(user, Repo.reload!(membership))
      end)

    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), read.pid)

    assert_receive {:connection_effects_paused, effects_pid, ^effects_ref, connection_id}, 5_000
    assert connection_id == connection.id
    assert Repo.reload!(membership).unread_count == 0

    Application.delete_env(:ircpipe_core, :connection_effects_before_lock_barrier)

    assert {:ok, _message} =
             MessageIngestion.record_channel(connection, membership.channel, "akash", "newer")

    assert_receive {:buffer_message, %{unread_count: 1, mention_count: 0}}

    send(effects_pid, {:continue_connection_effects, effects_ref})
    assert :ok = Task.await(read, 5_000)
    assert Repo.reload!(membership).unread_count == 1
    assert_receive {:buffer_read, %{unread_count: 1, mention_count: 0}}
  end

  test "rejects buffers owned by another user" do
    owner = AccountsFixtures.user_fixture()
    other_user = AccountsFixtures.user_fixture()
    connection = connection_fixture(owner)
    {:ok, membership} = Ircpipe.Chat.join_channel(owner, connection, "#elixir")

    assert {:error, :invalid_buffer} = ReadState.mark(other_user, membership)
    assert {:error, :invalid_buffer} = ReadState.mark(other_user, connection)
  end

  test "rejects forged server connection ownership" do
    owner = AccountsFixtures.user_fixture()
    other_user = AccountsFixtures.user_fixture()
    connection = connection_fixture(owner)
    forged_connection = %{connection | user_id: other_user.id}

    Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{other_user.id}")

    assert {:error, :invalid_buffer} = ReadState.mark(other_user, forged_connection)
    refute_received {:buffer_read, _payload}
  end

  test "rejects channel and server reads after connection deletion is marked" do
    user = AccountsFixtures.user_fixture()
    connection = connection_fixture(user)
    {:ok, membership} = Ircpipe.Chat.join_channel(user, connection, "#elixir")

    {:ok, _channel_message} =
      MessageIngestion.record_channel(connection, membership.channel, "akash", "mira: ping")

    {:ok, _server_message} = MessageIngestion.record_server(connection, "Connected")
    Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{user.id}")

    connection
    |> Ecto.Changeset.change(deleting: true)
    |> Repo.update!()

    assert {:error, :connection_deleting} = ReadState.mark(user, Repo.reload!(membership))
    assert {:error, :connection_deleting} = ReadState.mark(user, Repo.reload!(connection))
    assert Repo.reload!(membership).unread_count == 1
    assert Repo.reload!(connection).unread_count == 1
    refute_received {:buffer_read, _payload}
  end

  test "completed deletion between a read commit and effects drops publication" do
    supervisor = start_supervised!(Task.Supervisor)
    user = AccountsFixtures.user_fixture()
    connection = connection_fixture(user)
    {:ok, _server_message} = MessageIngestion.record_server(connection, "Connected")
    Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{user.id}")

    effects_ref = make_ref()
    previous_barrier = Application.get_env(:ircpipe_core, :connection_effects_before_lock_barrier)

    Application.put_env(
      :ircpipe_core,
      :connection_effects_before_lock_barrier,
      {self(), effects_ref}
    )

    on_exit(fn ->
      restore_env(:connection_effects_before_lock_barrier, previous_barrier)
    end)

    read =
      Task.Supervisor.async_nolink(supervisor, fn ->
        ReadState.mark(user, connection)
      end)

    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), read.pid)

    assert_receive {:connection_effects_paused, effects_pid, ^effects_ref, connection_id}, 5_000
    assert connection_id == connection.id
    assert Repo.reload!(connection).unread_count == 0

    assert {:ok, deleted} = Connections.delete(user, connection.id)
    assert deleted.id == connection.id

    send(effects_pid, {:continue_connection_effects, effects_ref})
    assert :ok = Task.await(read, 5_000)
    refute_received {:buffer_read, _payload}
  end

  test "rejects an outer transaction before updating or publishing" do
    user = AccountsFixtures.user_fixture()
    connection = connection_fixture(user)
    {:ok, membership} = Ircpipe.Chat.join_channel(user, connection, "#elixir")

    {:ok, _message} =
      MessageIngestion.record_channel(connection, membership.channel, "akash", "mira: ping")

    {:ok, _server_message} = MessageIngestion.record_server(connection, "Connected")
    Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{user.id}")

    assert {:error, :forced_rollback} =
             Repo.transaction(fn ->
               assert_raise ArgumentError,
                            ~r/cannot mark buffers read inside an existing transaction/,
                            fn ->
                              ReadState.mark(user, Repo.reload!(membership))
                            end

               assert_raise ArgumentError,
                            ~r/cannot mark buffers read inside an existing transaction/,
                            fn ->
                              ReadState.mark(user, Repo.reload!(connection))
                            end

               Repo.rollback(:forced_rollback)
             end)

    assert Repo.reload!(membership).unread_count == 1
    assert Repo.reload!(connection).unread_count == 1
    refute_received {:buffer_read, _payload}
  end

  defp connection_fixture(user) do
    {:ok, connection} =
      Connections.create(user, %{
        "name" => "read-state-test",
        "host" => "irc.example.com",
        "nickname" => "mira"
      })

    connection
  end

  defp restore_env(key, nil), do: Application.delete_env(:ircpipe_core, key)
  defp restore_env(key, value), do: Application.put_env(:ircpipe_core, key, value)
end
