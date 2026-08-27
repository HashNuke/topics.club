defmodule Ircpipe.Chat.ConnectionDeletionWorkerTest do
  use Ircpipe.DataCase, async: false
  use Oban.Testing, repo: Ircpipe.Repo

  import ExUnit.CaptureLog

  alias Ircpipe.AccountsFixtures

  alias Ircpipe.Chat.{
    ConnectionDeletionRequest,
    ConnectionDeletionReconcilerWorker,
    ConnectionDeletionWorker
  }

  alias Ircpipe.Chat.Connections
  alias Ircpipe.Chat.ServerConnection
  alias Ircpipe.Repo

  test "a durable job resumes deletion when the request dies after marking" do
    task_supervisor = start_supervised!(Task.Supervisor)
    user = AccountsFixtures.user_fixture()

    assert {:ok, connection} =
             Connections.create(user, %{
               "name" => "request crash recovery",
               "host" => "irc.request-crash.test",
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
    end)

    _delete_task =
      Task.Supervisor.async_nolink(task_supervisor, fn ->
        Connections.delete(user, connection.id)
      end)

    assert_receive {:connection_delete_marked, delete_pid, ^barrier_ref, connection_id}, 5_000
    assert connection_id == connection.id
    delete_ref = Process.monitor(delete_pid)
    Process.exit(delete_pid, :kill)
    assert_receive {:DOWN, ^delete_ref, :process, ^delete_pid, :killed}

    assert Connections.list(user) == []
    assert_raise Ecto.NoResultsError, fn -> Connections.get!(user, connection.id) end

    assert {:ok, replacement} =
             Connections.create_or_get(user, %{
               "name" => "request crash replacement",
               "host" => "IRC.REQUEST-CRASH.TEST",
               "nickname" => "mira"
             })

    refute replacement.id == connection.id
    assert Enum.map(Connections.list(user), & &1.id) == [replacement.id]

    assert_enqueued(
      worker: ConnectionDeletionWorker,
      args: %{user_id: user.id, connection_id: connection.id}
    )

    assert :ok =
             perform_job(ConnectionDeletionWorker, %{
               user_id: user.id,
               connection_id: connection.id
             })

    assert Repo.get(ServerConnection, connection.id) == nil
    assert Repo.get!(ServerConnection, replacement.id).id == replacement.id
  end

  test "a durable job resumes deletion when the request dies after quiescing" do
    task_supervisor = start_supervised!(Task.Supervisor)
    user = AccountsFixtures.user_fixture()

    assert {:ok, connection} =
             Connections.create(user, %{
               "name" => "pre-marker request crash",
               "host" => "irc.pre-marker-crash.test",
               "nickname" => "mira"
             })

    barrier_ref = make_ref()
    previous_barrier = Application.get_env(:ircpipe, :connection_delete_after_quiesce_barrier)

    Application.put_env(
      :ircpipe,
      :connection_delete_after_quiesce_barrier,
      {self(), barrier_ref}
    )

    on_exit(fn ->
      restore_env(:connection_delete_after_quiesce_barrier, previous_barrier)
    end)

    _delete_task =
      Task.Supervisor.async_nolink(task_supervisor, fn ->
        Connections.delete(user, connection.id)
      end)

    assert_receive {:connection_delete_quiesced, delete_pid, ^barrier_ref, connection_id}, 5_000
    assert connection_id == connection.id

    assert_enqueued(
      worker: ConnectionDeletionWorker,
      args: %{user_id: user.id, connection_id: connection.id}
    )

    delete_monitor = Process.monitor(delete_pid)
    Process.exit(delete_pid, :kill)
    assert_receive {:DOWN, ^delete_monitor, :process, ^delete_pid, :killed}

    refute Repo.get!(ServerConnection, connection.id).deleting
    Application.delete_env(:ircpipe, :connection_delete_after_quiesce_barrier)

    assert :ok =
             perform_job(ConnectionDeletionWorker, %{
               user_id: user.id,
               connection_id: connection.id
             })

    assert Repo.get(ServerConnection, connection.id) == nil
  end

  test "a durable job snoozes without exhausting attempts after final deletion rolls back" do
    user = AccountsFixtures.user_fixture()

    assert {:ok, connection} =
             Connections.create(user, %{
               "name" => "final delete recovery",
               "host" => "irc.final-delete.test",
               "nickname" => "mira"
             })

    failure_ref = make_ref()
    previous_failure = Application.get_env(:ircpipe, :connection_final_delete_failure)

    Application.put_env(
      :ircpipe,
      :connection_final_delete_failure,
      {self(), failure_ref}
    )

    on_exit(fn ->
      restore_env(:connection_final_delete_failure, previous_failure)
    end)

    assert {:error, :forced_final_delete_failure} = Connections.delete(user, connection.id)

    assert_receive {:connection_final_delete_failed, _delete_pid, ^failure_ref, connection_id}
    assert connection_id == connection.id
    assert Repo.get!(ServerConnection, connection.id).deleting
    assert Connections.list(user) == []

    assert_enqueued(
      worker: ConnectionDeletionWorker,
      args: %{user_id: user.id, connection_id: connection.id}
    )

    log =
      capture_log(fn ->
        assert {:snooze, {1, :minute}} =
                 perform_job(
                   ConnectionDeletionWorker,
                   %{user_id: user.id, connection_id: connection.id},
                   attempt: 20,
                   max_attempts: 20
                 )
      end)

    assert log =~ "Connection deletion failed; snoozing before retry"
    assert Repo.get!(ServerConnection, connection.id).deleting

    Application.delete_env(:ircpipe, :connection_final_delete_failure)

    assert :ok =
             perform_job(
               ConnectionDeletionWorker,
               %{user_id: user.id, connection_id: connection.id},
               attempt: 20,
               max_attempts: 20
             )

    assert Repo.get(ServerConnection, connection.id) == nil
  end

  test "the reconciler replaces a deletion job discarded by an exception on its final attempt" do
    user = AccountsFixtures.user_fixture()

    assert {:ok, connection} =
             Connections.create(user, %{
               "name" => "discard recovery",
               "host" => "irc.discard-recovery.test",
               "nickname" => "mira"
             })

    failure_ref = make_ref()
    previous_failure = Application.get_env(:ircpipe, :connection_final_delete_failure)
    previous_exception = Application.get_env(:ircpipe, :connection_final_delete_exception)

    Application.put_env(
      :ircpipe,
      :connection_final_delete_failure,
      {self(), failure_ref}
    )

    on_exit(fn ->
      restore_env(:connection_final_delete_failure, previous_failure)
      restore_env(:connection_final_delete_exception, previous_exception)
    end)

    assert {:error, :forced_final_delete_failure} = Connections.delete(user, connection.id)
    assert_receive {:connection_final_delete_failed, _pid, ^failure_ref, connection_id}
    assert connection_id == connection.id

    Application.delete_env(:ircpipe, :connection_final_delete_failure)
    exception_ref = make_ref()

    Application.put_env(
      :ircpipe,
      :connection_final_delete_exception,
      {self(), exception_ref}
    )

    [job] =
      all_enqueued(
        worker: ConnectionDeletionWorker,
        args: %{user_id: user.id, connection_id: connection.id}
      )

    {_cancelled_count, nil} =
      Repo.update_all(
        from(persisted_job in Oban.Job,
          where:
            persisted_job.queue == "connection_deletions" and persisted_job.id != ^job.id and
              persisted_job.state in ["available", "scheduled", "retryable"]
        ),
        set: [state: "cancelled", cancelled_at: DateTime.utc_now()]
      )

    {1, nil} =
      Repo.update_all(
        from(persisted_job in Oban.Job, where: persisted_job.id == ^job.id),
        set: [attempt: 19, max_attempts: 20, state: "available"]
      )

    assert %{discard: 1, failure: 0, snoozed: 0, success: 0} =
             Oban.drain_queue(Ircpipe.EngineOban,
               queue: :connection_deletions,
               with_limit: 1
             )

    assert_receive {:connection_final_delete_raised, _pid, ^exception_ref, ^connection_id}
    assert Repo.get!(Oban.Job, job.id).state == "discarded"
    assert Repo.get!(ServerConnection, connection.id).deleting

    Application.delete_env(:ircpipe, :connection_final_delete_exception)

    assert :ok = perform_job(ConnectionDeletionReconcilerWorker, %{})

    replacement_job =
      ConnectionDeletionWorker
      |> Oban.Worker.to_string()
      |> then(fn worker ->
        Repo.one!(
          from persisted_job in Oban.Job,
            where:
              persisted_job.worker == ^worker and persisted_job.id != ^job.id and
                persisted_job.state in ["available", "scheduled", "retryable"]
        )
      end)

    assert replacement_job.args == %{
             "user_id" => user.id,
             "connection_id" => connection.id
           }

    assert :ok = perform_job(ConnectionDeletionWorker, replacement_job.args)
    assert Repo.get(ServerConnection, connection.id) == nil
  end

  test "the reconciler replaces a discarded pre-marker deletion request" do
    user = AccountsFixtures.user_fixture()

    assert {:ok, connection} =
             Connections.create(user, %{
               "name" => "pre-marker discard recovery",
               "host" => "irc.pre-marker-discard.test",
               "nickname" => "mira"
             })

    exception_ref = make_ref()
    previous_exception = Application.get_env(:ircpipe, :connection_before_delete_mark_exception)

    Application.put_env(
      :ircpipe,
      :connection_before_delete_mark_exception,
      {self(), exception_ref}
    )

    on_exit(fn ->
      restore_env(:connection_before_delete_mark_exception, previous_exception)
    end)

    assert_raise RuntimeError, "forced pre-marker deletion exception", fn ->
      Connections.delete(user, connection.id)
    end

    assert_receive {:connection_before_delete_mark_raised, _pid, ^exception_ref, connection_id}
    assert connection_id == connection.id
    refute Repo.get!(ServerConnection, connection.id).deleting

    assert Repo.get_by!(ConnectionDeletionRequest, server_connection_id: connection.id).user_id ==
             user.id

    [job] =
      all_enqueued(
        worker: ConnectionDeletionWorker,
        args: %{user_id: user.id, connection_id: connection.id}
      )

    {_cancelled_count, nil} =
      Repo.update_all(
        from(persisted_job in Oban.Job,
          where:
            persisted_job.queue == "connection_deletions" and persisted_job.id != ^job.id and
              persisted_job.state in ["available", "scheduled", "retryable"]
        ),
        set: [state: "cancelled", cancelled_at: DateTime.utc_now()]
      )

    {1, nil} =
      Repo.update_all(
        from(persisted_job in Oban.Job, where: persisted_job.id == ^job.id),
        set: [attempt: 19, max_attempts: 20, state: "available"]
      )

    assert %{discard: 1, failure: 0, snoozed: 0, success: 0} =
             Oban.drain_queue(Ircpipe.EngineOban,
               queue: :connection_deletions,
               with_limit: 1
             )

    assert_receive {:connection_before_delete_mark_raised, _pid, ^exception_ref, ^connection_id}
    assert Repo.get!(Oban.Job, job.id).state == "discarded"
    refute Repo.get!(ServerConnection, connection.id).deleting

    Application.delete_env(:ircpipe, :connection_before_delete_mark_exception)
    assert :ok = perform_job(ConnectionDeletionReconcilerWorker, %{})

    replacement_job =
      ConnectionDeletionWorker
      |> Oban.Worker.to_string()
      |> then(fn worker ->
        Repo.one!(
          from persisted_job in Oban.Job,
            where:
              persisted_job.worker == ^worker and persisted_job.id != ^job.id and
                persisted_job.state in ["available", "scheduled", "retryable"]
        )
      end)

    assert :ok = perform_job(ConnectionDeletionWorker, replacement_job.args)
    assert Repo.get(ServerConnection, connection.id) == nil
    refute Repo.get_by(ConnectionDeletionRequest, server_connection_id: connection.id)
  end

  defp restore_env(key, nil), do: Application.delete_env(:ircpipe, key)
  defp restore_env(key, value), do: Application.put_env(:ircpipe, key, value)
end
