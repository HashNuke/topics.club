defmodule Ircpipe.Chat.ConnectionDeletionTest do
  use Ircpipe.DataCase, async: false
  use Oban.Testing, repo: Ircpipe.Repo

  alias Ircpipe.AccountsFixtures
  alias Ircpipe.Chat

  alias Ircpipe.Chat.{
    ChannelMembership,
    ChannelUser,
    ConnectionDeletion,
    ConnectionDeletionEventBatch,
    ConnectionDeletionEventsWorker,
    ConnectionDeletionReconcilerWorker,
    Connections,
    DirectMessageLifecycle,
    DirectMessageThread,
    Message,
    MessageIngestion,
    Notification
  }

  alias Ircpipe.Irc.{CommandRegistry, Session, SessionLocator}
  alias Ircpipe.Irc.Session.JoinLifecycle
  alias Ircpipe.Irc.SessionSupervisor
  alias Ircpipe.IrcTestServer
  alias Ircpipe.Notifications.PushWorker
  alias Ircpipe.Repo

  test "a session start that wins the deletion race is stopped before row deletion" do
    server = start_supervised!({IrcTestServer, self()})
    task_supervisor = start_supervised!(Task.Supervisor)
    user = AccountsFixtures.user_fixture()

    assert {:ok, connection} =
             Connections.create(user, %{
               "name" => "session race",
               "host" => "127.0.0.1",
               "port" => IrcTestServer.port(server),
               "use_tls" => false,
               "nickname" => "mira"
             })

    barrier_ref = make_ref()
    previous_barrier = Application.get_env(:ircpipe, :session_start_after_lookup_barrier)

    Application.put_env(
      :ircpipe,
      :session_start_after_lookup_barrier,
      {self(), barrier_ref}
    )

    on_exit(fn ->
      restore_env(:session_start_after_lookup_barrier, previous_barrier)
      _ = SessionSupervisor.stop_session(connection)
    end)

    start_task =
      Task.Supervisor.async_nolink(task_supervisor, fn ->
        SessionSupervisor.start_session(connection)
      end)

    assert_receive {:session_start_paused, start_pid, ^barrier_ref, connection_id}, 5_000
    assert connection_id == connection.id

    delete_task =
      Task.Supervisor.async_nolink(task_supervisor, fn ->
        ConnectionDeletion.delete(user, connection.id)
      end)

    refute Task.yield(delete_task, 100)
    send(start_pid, {:continue_session_start, barrier_ref})

    assert {:ok, session_pid} = Task.await(start_task, 5_000)
    session_ref = Process.monitor(session_pid)

    assert {:ok, deleted} = Task.await(delete_task, 5_000)
    assert deleted.id == connection.id
    assert_receive {:DOWN, ^session_ref, :process, ^session_pid, :shutdown}, 5_000

    assert SessionLocator.whereis(connection) == nil
    assert Repo.get(Ircpipe.Chat.ServerConnection, connection.id) == nil
  end

  test "a stale connection cannot start a session after deletion commits" do
    user = AccountsFixtures.user_fixture()

    assert {:ok, connection} =
             Connections.create(user, %{
               "name" => "stale start",
               "host" => "irc.stale.test",
               "nickname" => "mira"
             })

    assert {:ok, deleted} = ConnectionDeletion.delete(user, connection.id)
    assert deleted.id == connection.id

    assert {:error, :connection_not_found} = SessionSupervisor.start_session(connection)
    assert SessionLocator.whereis(connection) == nil
  end

  test "a normal disconnect tears down the IRC client before deletion" do
    server = start_supervised!({IrcTestServer, self()})
    user = AccountsFixtures.user_fixture()

    assert {:ok, connection} =
             Connections.create(user, %{
               "name" => "normal disconnect teardown",
               "host" => "127.0.0.1",
               "port" => IrcTestServer.port(server),
               "use_tls" => false,
               "nickname" => "ircpipe"
             })

    assert {:ok, _session_pid} = SessionSupervisor.start_session(connection)
    assert_receive {:irc_server_line, "NICK ircpipe"}, 5_000

    registry_key = {connection.user_id, connection.id}

    assert [{client_pid, nil}] = Registry.lookup(Ircpipe.Irc.ClientRegistry, registry_key)

    client_monitor = Process.monitor(client_pid)

    assert :ok = SessionSupervisor.stop_session(connection, "user disconnected")
    assert_receive {:irc_server_line, "QUIT :user disconnected"}, 5_000
    assert_receive {:DOWN, ^client_monitor, :process, ^client_pid, :shutdown}, 5_000
    assert Registry.lookup(Ircpipe.Irc.ClientRegistry, registry_key) == []

    assert {:ok, deleted} = ConnectionDeletion.delete(user, connection.id)
    assert deleted.id == connection.id
    _send_result = send_after_disconnect(server, "PING :after-delete")
    refute_receive {:irc_server_line, "PONG " <> _token}, 100
  end

  test "a deletion mark prevents a late session start before row deletion" do
    task_supervisor = start_supervised!(Task.Supervisor)
    user = AccountsFixtures.user_fixture()

    assert {:ok, connection} =
             Connections.create(user, %{
               "name" => "marked deletion",
               "host" => "irc.marked-deletion.test",
               "nickname" => "mira"
             })

    barrier_ref = make_ref()
    previous_barrier = Application.get_env(:ircpipe, :connection_delete_after_mark_barrier)

    Application.put_env(
      :ircpipe,
      :connection_delete_after_mark_barrier,
      {self(), barrier_ref}
    )

    on_exit(fn ->
      restore_env(:connection_delete_after_mark_barrier, previous_barrier)
      _ = SessionSupervisor.stop_session(connection)
    end)

    delete_task =
      Task.Supervisor.async_nolink(task_supervisor, fn ->
        ConnectionDeletion.delete(user, connection.id)
      end)

    assert_receive {:connection_delete_marked, delete_pid, ^barrier_ref, connection_id}, 5_000
    assert connection_id == connection.id
    assert {:error, :connection_not_found} = SessionSupervisor.start_session(connection)
    assert SessionLocator.whereis(connection) == nil

    send(delete_pid, {:continue_marked_connection_delete, barrier_ref})
    assert {:ok, deleted} = Task.await(delete_task, 5_000)
    assert deleted.id == connection.id
  end

  test "a stale live session cannot mutate or publish for a marked connection" do
    server = start_supervised!({IrcTestServer, self()})
    user = AccountsFixtures.user_fixture()

    assert {:ok, connection} =
             Connections.create(user, %{
               "name" => "marked live session",
               "host" => "127.0.0.1",
               "port" => IrcTestServer.port(server),
               "use_tls" => false,
               "nickname" => "ircpipe"
             })

    assert {:ok, membership} = Chat.join_channel(user, connection, "#guarded")
    assert {:ok, session_pid} = SessionSupervisor.start_session(connection)
    assert_receive {:irc_server_line, "JOIN #guarded"}, 5_000
    _ = :sys.get_state(session_pid)

    pending_membership =
      %ChannelMembership{user_id: user.id, server_connection_id: connection.id}
      |> ChannelMembership.changeset(%{
        channel: "#pending-after-mark",
        status: "pending",
        auto_join: true
      })
      |> Repo.insert!()

    assert {:ok, direct_thread} = DirectMessageLifecycle.open(user, connection, "akash")

    {:ok, client_info} = Session.connection_info(connection)
    {:ok, command_intent} = CommandRegistry.resolve("WHOIS akash", client_info)

    connection
    |> Ecto.Changeset.change(deleting: true)
    |> Repo.update!()

    on_exit(fn ->
      _ = SessionSupervisor.stop_for_deletion(connection)
    end)

    assert SessionLocator.whereis(connection) == session_pid

    Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{user.id}")
    initial_jobs = Repo.aggregate(Oban.Job, :count)

    assert {:error, :connection_deleting} = Session.say(connection, "#guarded", "never sent")

    assert {:error, :connection_deleting} =
             Session.action(connection, "#guarded", "never waves")

    assert {:error, %{code: "connection_deleting"}} =
             Session.execute(
               connection,
               command_intent,
               "deleting-command",
               "server:#{connection.id}"
             )

    assert {:error, :connection_deleting} =
             Session.request_join(connection, user, "#after-mark")

    assert {:error, :connection_deleting} = Session.part(connection, "#guarded")

    assert {:error, :connection_deleting} = Session.list_channels(connection)

    session_pid
    |> :sys.get_state()
    |> JoinLifecycle.flush()

    refute_receive {:irc_server_line, "PRIVMSG #guarded never sent"}, 100
    refute_receive {:irc_server_line, "PRIVMSG #guarded :\x01ACTION never waves\x01"}, 100
    refute_receive {:irc_server_line, "WHOIS akash"}, 100
    refute_receive {:irc_server_line, "JOIN #after-mark"}, 100
    refute_receive {:irc_server_line, "PART #guarded" <> _reason}, 100
    refute_receive {:irc_server_line, "LIST"}, 100
    refute_receive {:irc_server_line, "JOIN #pending-after-mark"}, 100

    send(
      session_pid,
      {:ircxd,
       {:join,
        %{
          channel: pending_membership.channel,
          nick: "ircpipe",
          raw_source: "ircpipe!user@test"
        }}}
    )

    send(
      session_pid,
      {:ircxd,
       {:part,
        %{
          channel: membership.channel,
          nick: "ircpipe",
          raw_source: "ircpipe!user@test"
        }}}
    )

    send(
      session_pid,
      {:ircxd,
       {:nick,
        %{
          old_nick: "akash",
          new_nick: "renamed-too-late",
          raw_source: "akash!user@test"
        }}}
    )

    send(
      session_pid,
      {:ircxd,
       {:nick,
        %{
          old_nick: "ircpipe",
          new_nick: "self-too-late",
          raw_source: "ircpipe!user@test"
        }}}
    )

    send(
      session_pid,
      {:ircxd,
       {:privmsg,
        %{
          target: "#guarded",
          nick: "akash",
          raw_source: "akash!user@test",
          body: "channel after deletion mark"
        }}}
    )

    send(
      session_pid,
      {:ircxd,
       {:privmsg,
        %{
          target: "ircpipe",
          nick: "akash",
          raw_source: "akash!user@test",
          body: "private after deletion mark"
        }}}
    )

    send(
      session_pid,
      {:ircxd,
       {:join,
        %{
          channel: "#guarded",
          nick: "late-user",
          raw_source: "late-user!user@test"
        }}}
    )

    _ = :sys.get_state(session_pid)

    refute Repo.get_by(Message, body: "channel after deletion mark")
    refute Repo.get_by(Message, body: "private after deletion mark")
    refute Repo.get_by(Message, body: "late-user joined #guarded.")
    refute Repo.get_by(Notification, user_id: user.id)
    refute Repo.get_by(ChannelUser, channel_membership_id: membership.id, nick: "late-user")
    assert Repo.get!(ChannelMembership, pending_membership.id).status == "pending"
    assert Repo.get!(ChannelMembership, membership.id).status == "joined"
    assert Repo.get!(DirectMessageThread, direct_thread.id).peer_nick == "akash"
    assert Repo.get!(Ircpipe.Chat.ServerConnection, connection.id).nickname == "ircpipe"
    assert SessionLocator.whereis(connection) == session_pid
    assert Repo.aggregate(Oban.Job, :count) == initial_jobs
    refute_received {:direct_message_thread, _event}
    refute_received {:buffer_message, _event}
    refute_received {:presence_diff, _event}
  end

  test "a deletion mark that wins the init-to-connect gap prevents all IRC wire traffic" do
    server = start_supervised!({IrcTestServer, self()})
    task_supervisor = start_supervised!(Task.Supervisor)
    user = AccountsFixtures.user_fixture()

    assert {:ok, connection} =
             Connections.create(user, %{
               "name" => "connect gap",
               "host" => "127.0.0.1",
               "port" => IrcTestServer.port(server),
               "use_tls" => false,
               "nickname" => "ircpipe"
             })

    connect_ref = make_ref()
    delete_ref = make_ref()
    previous_connect_barrier = Application.get_env(:ircpipe, :session_connect_before_lock_barrier)
    previous_delete_barrier = Application.get_env(:ircpipe, :connection_delete_after_mark_barrier)

    Application.put_env(
      :ircpipe,
      :session_connect_before_lock_barrier,
      {self(), connect_ref}
    )

    Application.put_env(
      :ircpipe,
      :connection_delete_after_mark_barrier,
      {self(), delete_ref}
    )

    on_exit(fn ->
      restore_env(:session_connect_before_lock_barrier, previous_connect_barrier)
      restore_env(:connection_delete_after_mark_barrier, previous_delete_barrier)
      _ = SessionSupervisor.stop_session(connection)
    end)

    assert {:ok, session_pid} = SessionSupervisor.start_session(connection)
    session_monitor = Process.monitor(session_pid)

    assert_receive {:session_connect_paused, connect_pid, ^connect_ref, connection_id}, 5_000
    assert connect_pid == session_pid
    assert connection_id == connection.id

    delete_task =
      Task.Supervisor.async_nolink(task_supervisor, fn ->
        ConnectionDeletion.delete(user, connection.id)
      end)

    assert_receive {:connection_delete_marked, delete_pid, ^delete_ref, ^connection_id}, 5_000
    send(connect_pid, {:continue_session_connect, connect_ref})
    assert_receive {:DOWN, ^session_monitor, :process, ^session_pid, :shutdown}, 5_000
    refute_receive {:irc_server_line, "NICK " <> _nick}, 100
    refute_receive {:irc_server_line, "USER " <> _user}, 100

    send(delete_pid, {:continue_marked_connection_delete, delete_ref})
    assert {:ok, deleted} = Task.await(delete_task, 5_000)
    assert deleted.id == connection.id
  end

  test "deletion quiesces an initialized IRC client before the deletion mark commits" do
    server = start_supervised!({IrcTestServer, self()})
    task_supervisor = start_supervised!(Task.Supervisor)
    user = AccountsFixtures.user_fixture()

    assert {:ok, connection} =
             Connections.create(user, %{
               "name" => "initialized client gap",
               "host" => "127.0.0.1",
               "port" => IrcTestServer.port(server),
               "use_tls" => false,
               "nickname" => "ircpipe"
             })

    client_ref = make_ref()
    delete_ref = make_ref()

    previous_client_barrier =
      Application.get_env(:ircpipe, :session_client_after_start_barrier)

    previous_delete_barrier = Application.get_env(:ircpipe, :connection_delete_after_mark_barrier)

    Application.put_env(
      :ircpipe,
      :session_client_after_start_barrier,
      {self(), client_ref}
    )

    Application.put_env(
      :ircpipe,
      :connection_delete_after_mark_barrier,
      {self(), delete_ref}
    )

    on_exit(fn ->
      restore_env(:session_client_after_start_barrier, previous_client_barrier)
      restore_env(:connection_delete_after_mark_barrier, previous_delete_barrier)
      _ = SessionSupervisor.stop_for_deletion(connection)
    end)

    assert {:ok, session_pid} = SessionSupervisor.start_session(connection)
    session_monitor = Process.monitor(session_pid)

    assert_receive {:irc_client_suspended, client_pid, ^client_ref, connection_id}, 5_000
    assert connection_id == connection.id
    client_monitor = Process.monitor(client_pid)

    delete_task =
      Task.Supervisor.async_nolink(task_supervisor, fn ->
        ConnectionDeletion.delete(user, connection.id)
      end)

    assert_receive {:connection_delete_marked, delete_pid, ^delete_ref, connection_id}, 5_000
    assert connection_id == connection.id
    assert_receive {:DOWN, ^client_monitor, :process, ^client_pid, :shutdown}, 5_000
    assert_receive {:DOWN, ^session_monitor, :process, ^session_pid, :shutdown}, 5_000

    refute_receive {:irc_server_line, "PASS " <> _password}, 100
    refute_receive {:irc_server_line, "CAP " <> _capabilities}, 100
    refute_receive {:irc_server_line, "NICK " <> _nick}, 100
    refute_receive {:irc_server_line, "USER " <> _user}, 100
    refute_receive {:irc_server_line, "QUIT" <> _reason}, 100

    send(delete_pid, {:continue_marked_connection_delete, delete_ref})
    assert {:ok, deleted} = Task.await(delete_task, 5_000)
    assert deleted.id == connection.id
  end

  test "deletion marking between commit and effects suppresses notification and publication" do
    task_supervisor = start_supervised!(Task.Supervisor)
    user = AccountsFixtures.user_fixture()

    assert {:ok, connection} =
             Connections.create(user, %{
               "name" => "post-commit effects race",
               "host" => "irc.effects-race.test",
               "nickname" => "mira"
             })

    assert {:ok, membership} = Chat.join_channel(user, connection, "#guarded")
    Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{user.id}")

    effects_ref = make_ref()
    delete_ref = make_ref()

    previous_effects_barrier =
      Application.get_env(:ircpipe, :connection_effects_before_lock_barrier)

    previous_delete_barrier = Application.get_env(:ircpipe, :connection_delete_after_mark_barrier)

    Application.put_env(
      :ircpipe,
      :connection_effects_before_lock_barrier,
      {self(), effects_ref}
    )

    Application.put_env(
      :ircpipe,
      :connection_delete_after_mark_barrier,
      {self(), delete_ref}
    )

    on_exit(fn ->
      restore_env(:connection_effects_before_lock_barrier, previous_effects_barrier)
      restore_env(:connection_delete_after_mark_barrier, previous_delete_barrier)
    end)

    ingestion_task =
      Task.Supervisor.async_nolink(task_supervisor, fn ->
        MessageIngestion.record_channel(
          connection,
          membership.channel,
          "akash",
          "mira: committed before deletion"
        )
      end)

    assert_receive {:connection_effects_paused, effects_pid, ^effects_ref, connection_id}, 5_000
    assert connection_id == connection.id
    assert Repo.get_by(Message, body: "mira: committed before deletion")
    assert Repo.get_by(Notification, user_id: user.id)

    delete_task =
      Task.Supervisor.async_nolink(task_supervisor, fn ->
        ConnectionDeletion.delete(user, connection.id)
      end)

    assert_receive {:connection_delete_marked, delete_pid, ^delete_ref, ^connection_id}, 5_000
    jobs_after_mark = Repo.aggregate(Oban.Job, :count)

    send(effects_pid, {:continue_connection_effects, effects_ref})
    assert {:ok, _message} = Task.await(ingestion_task, 5_000)

    assert Repo.aggregate(Oban.Job, :count) == jobs_after_mark
    refute_received {:buffer_message, _event}

    send(delete_pid, {:continue_marked_connection_delete, delete_ref})
    assert {:ok, deleted} = Task.await(delete_task, 5_000)
    assert deleted.id == connection.id
  end

  test "completed deletion between commit and effects drops publication without raising" do
    task_supervisor = start_supervised!(Task.Supervisor)
    user = AccountsFixtures.user_fixture()

    assert {:ok, connection} =
             Connections.create(user, %{
               "name" => "deleted effects race",
               "host" => "irc.deleted-effects.test",
               "nickname" => "mira"
             })

    assert {:ok, membership} = Chat.join_channel(user, connection, "#guarded")
    Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{user.id}")

    effects_ref = make_ref()

    previous_effects_barrier =
      Application.get_env(:ircpipe, :connection_effects_before_lock_barrier)

    Application.put_env(
      :ircpipe,
      :connection_effects_before_lock_barrier,
      {self(), effects_ref}
    )

    on_exit(fn ->
      restore_env(:connection_effects_before_lock_barrier, previous_effects_barrier)
    end)

    ingestion_task =
      Task.Supervisor.async_nolink(task_supervisor, fn ->
        MessageIngestion.record_channel(
          connection,
          membership.channel,
          "akash",
          "mira: deleted before effects"
        )
      end)

    assert_receive {:connection_effects_paused, effects_pid, ^effects_ref, connection_id}, 5_000
    assert connection_id == connection.id
    assert Repo.get_by(Message, body: "mira: deleted before effects")

    assert {:ok, deleted} = ConnectionDeletion.delete(user, connection.id)
    assert deleted.id == connection.id
    send(effects_pid, {:continue_connection_effects, effects_ref})
    assert {:ok, _message} = Task.await(ingestion_task, 5_000)

    refute Repo.get_by(Message, body: "mira: deleted before effects")
    assert all_enqueued(worker: PushWorker) == []
  end

  test "deletion completes when a session crashes after stop lookup" do
    server = start_supervised!({IrcTestServer, self()})
    task_supervisor = start_supervised!(Task.Supervisor)
    user = AccountsFixtures.user_fixture()

    assert {:ok, connection} =
             Connections.create(user, %{
               "name" => "stop crash",
               "host" => "127.0.0.1",
               "port" => IrcTestServer.port(server),
               "use_tls" => false,
               "nickname" => "mira"
             })

    assert {:ok, session_pid} = SessionSupervisor.start_session(connection)
    _ = :sys.get_state(SessionLocator.via(connection))
    session_ref = Process.monitor(session_pid)

    previous_pause = Application.get_env(:ircpipe, :pause_session_stop_after_lookup)
    Application.put_env(:ircpipe, :pause_session_stop_after_lookup, self())

    on_exit(fn ->
      restore_env(:pause_session_stop_after_lookup, previous_pause)
      _ = SessionSupervisor.stop_session(connection)
    end)

    delete_task =
      Task.Supervisor.async_nolink(task_supervisor, fn ->
        ConnectionDeletion.delete(user, connection.id)
      end)

    assert_receive {:session_stop_paused, stop_pid, ^session_pid}, 5_000
    refute Task.yield(delete_task, 100)
    Process.exit(session_pid, :kill)
    assert_receive {:DOWN, ^session_ref, :process, ^session_pid, :killed}, 5_000
    send(stop_pid, {:continue_session_stop, session_pid})

    assert {:ok, deleted} = Task.await(delete_task, 5_000)
    assert deleted.id == connection.id
    _ = :sys.get_state(SessionSupervisor)
    assert SessionLocator.whereis(connection) == nil
  end

  test "a durable event batch closes the post-commit broadcast crash gap" do
    task_supervisor = start_supervised!(Task.Supervisor)
    user = AccountsFixtures.user_fixture()

    assert {:ok, connection} =
             Connections.create(user, %{
               "name" => "event outbox",
               "host" => "irc.event-outbox.test",
               "nickname" => "mira"
             })

    assert {:ok, membership} = Chat.join_channel(user, connection, "#durable")
    Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{user.id}")

    barrier_ref = make_ref()
    previous_barrier = Application.get_env(:ircpipe, :connection_delete_after_commit_barrier)

    Application.put_env(
      :ircpipe,
      :connection_delete_after_commit_barrier,
      {self(), barrier_ref}
    )

    on_exit(fn ->
      restore_env(:connection_delete_after_commit_barrier, previous_barrier)
    end)

    _delete_task =
      Task.Supervisor.async_nolink(task_supervisor, fn ->
        ConnectionDeletion.delete(user, connection.id)
      end)

    assert_receive {:connection_delete_committed, delete_pid, ^barrier_ref, batch_id}, 5_000
    delete_ref = Process.monitor(delete_pid)

    assert Repo.get(Ircpipe.Chat.ServerConnection, connection.id) == nil
    refute_receive {:buffer_left, _event}

    Process.exit(delete_pid, :kill)
    assert_receive {:DOWN, ^delete_ref, :process, ^delete_pid, :killed}

    batch = Repo.get!(ConnectionDeletionEventBatch, batch_id)

    [discarded_job] =
      all_enqueued(
        worker: ConnectionDeletionEventsWorker,
        args: %{event_batch_id: batch.id}
      )

    {1, nil} =
      Repo.update_all(
        from(persisted_job in Oban.Job, where: persisted_job.id == ^discarded_job.id),
        set: [
          attempt: discarded_job.max_attempts,
          state: "discarded",
          discarded_at: DateTime.utc_now()
        ]
      )

    assert :ok = perform_job(ConnectionDeletionReconcilerWorker, %{})

    event_worker = Oban.Worker.to_string(ConnectionDeletionEventsWorker)

    replacement_job =
      Repo.one!(
        from persisted_job in Oban.Job,
          where:
            persisted_job.worker == ^event_worker and
              persisted_job.id != ^discarded_job.id and
              persisted_job.state in ["available", "scheduled", "retryable"]
      )

    assert replacement_job.args == %{"event_batch_id" => batch.id}

    assert :ok =
             perform_job(ConnectionDeletionEventsWorker, replacement_job.args)

    assert_receive {:buffer_left,
                    %{
                      event_id: channel_event_id,
                      buffer_id: "channel:" <> _,
                      channel_membership_id: membership_id
                    }}

    assert membership_id == membership.id

    assert_receive {:buffer_left,
                    %{
                      event_id: server_event_id,
                      buffer_id: "server:" <> _,
                      channel_membership_id: nil
                    }}

    assert channel_event_id != server_event_id
    assert Repo.get(ConnectionDeletionEventBatch, batch.id) == nil

    assert :ok =
             perform_job(ConnectionDeletionEventsWorker, %{
               event_batch_id: batch.id
             })

    refute_receive {:buffer_left, _event}
  end

  defp restore_env(key, nil), do: Application.delete_env(:ircpipe, key)
  defp restore_env(key, value), do: Application.put_env(:ircpipe, key, value)

  defp send_after_disconnect(server, line) do
    IrcTestServer.send_line(server, line)
  catch
    :exit, _reason -> :closed
  end
end
