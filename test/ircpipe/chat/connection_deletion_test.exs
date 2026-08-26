defmodule Ircpipe.Chat.ConnectionDeletionTest do
  use Ircpipe.DataCase, async: false
  use Oban.Testing, repo: Ircpipe.Repo

  alias Ircpipe.AccountsFixtures
  alias Ircpipe.Chat

  alias Ircpipe.Chat.{
    ConnectionDeletionEventBatch,
    ConnectionDeletionEventsWorker,
    ConnectionDeletionReconcilerWorker,
    Connections
  }

  alias Ircpipe.Irc.Session
  alias Ircpipe.Irc.SessionSupervisor
  alias Ircpipe.IrcTestServer
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
        Connections.delete(user, connection.id)
      end)

    refute Task.yield(delete_task, 100)
    send(start_pid, {:continue_session_start, barrier_ref})

    assert {:ok, session_pid} = Task.await(start_task, 5_000)
    session_ref = Process.monitor(session_pid)

    assert {:ok, deleted} = Task.await(delete_task, 5_000)
    assert deleted.id == connection.id
    assert_receive {:DOWN, ^session_ref, :process, ^session_pid, :normal}, 5_000

    assert Session.whereis(connection) == nil
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

    assert {:ok, deleted} = Connections.delete(user, connection.id)
    assert deleted.id == connection.id

    assert {:error, :connection_not_found} = SessionSupervisor.start_session(connection)
    assert Session.whereis(connection) == nil
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
        Connections.delete(user, connection.id)
      end)

    assert_receive {:connection_delete_marked, delete_pid, ^barrier_ref, connection_id}, 5_000
    assert connection_id == connection.id
    assert {:error, :connection_not_found} = SessionSupervisor.start_session(connection)
    assert Session.whereis(connection) == nil

    send(delete_pid, {:continue_marked_connection_delete, barrier_ref})
    assert {:ok, deleted} = Task.await(delete_task, 5_000)
    assert deleted.id == connection.id
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
    _ = :sys.get_state(Session.via(connection))
    session_ref = Process.monitor(session_pid)

    previous_pause = Application.get_env(:ircpipe, :pause_session_stop_after_lookup)
    Application.put_env(:ircpipe, :pause_session_stop_after_lookup, self())

    on_exit(fn ->
      restore_env(:pause_session_stop_after_lookup, previous_pause)
      _ = SessionSupervisor.stop_session(connection)
    end)

    delete_task =
      Task.Supervisor.async_nolink(task_supervisor, fn ->
        Connections.delete(user, connection.id)
      end)

    assert_receive {:session_stop_paused, stop_pid, ^session_pid}, 5_000
    refute Task.yield(delete_task, 100)
    Process.exit(session_pid, :kill)
    assert_receive {:DOWN, ^session_ref, :process, ^session_pid, :killed}, 5_000
    send(stop_pid, {:continue_session_stop, session_pid})

    assert {:ok, deleted} = Task.await(delete_task, 5_000)
    assert deleted.id == connection.id
    _ = :sys.get_state(SessionSupervisor)
    assert Session.whereis(connection) == nil
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
        Connections.delete(user, connection.id)
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
end
