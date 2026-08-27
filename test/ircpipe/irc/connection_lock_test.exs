defmodule Ircpipe.Irc.ConnectionLockTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Ircpipe.Accounts.User
  alias Ircpipe.AccountsFixtures
  alias Ircpipe.Irc.ConnectionLock
  alias Ircpipe.Repo

  test "serializes the same connection key in the database" do
    task_supervisor = start_supervised!(Task.Supervisor)
    user_id = System.unique_integer([:positive])
    connection_id = System.unique_integer([:positive])
    test_pid = self()

    first_task =
      unboxed_task(task_supervisor, fn ->
        ConnectionLock.run(user_id, connection_id, fn ->
          send(test_pid, {:connection_lock_acquired, :first, self()})

          receive do
            :release_connection_lock -> :first_done
          end
        end)
      end)

    assert_receive {:connection_lock_acquired, :first, first_pid}

    second_task =
      unboxed_task(task_supervisor, fn ->
        send(test_pid, {:connection_lock_attempting, :second, self()})

        ConnectionLock.run(user_id, connection_id, fn ->
          send(test_pid, {:connection_lock_acquired, :second, self()})
          :second_done
        end)
      end)

    assert_receive {:connection_lock_attempting, :second, second_pid}
    refute_receive {:connection_lock_acquired, :second, ^second_pid}, 100

    send(first_pid, :release_connection_lock)
    assert :first_done = Task.await(first_task)
    assert_receive {:connection_lock_acquired, :second, ^second_pid}
    assert :second_done = Task.await(second_task)
  end

  test "allows different database lock keys to run independently" do
    task_supervisor = start_supervised!(Task.Supervisor)
    user_id = System.unique_integer([:positive])
    first_connection_id = System.unique_integer([:positive])
    second_connection_id = System.unique_integer([:positive])
    test_pid = self()

    first_task =
      unboxed_task(task_supervisor, fn ->
        ConnectionLock.run(user_id, first_connection_id, fn ->
          send(test_pid, {:connection_lock_acquired, :first_key, self()})

          receive do
            :release_connection_lock -> :first_done
          end
        end)
      end)

    assert_receive {:connection_lock_acquired, :first_key, first_pid}

    second_task =
      unboxed_task(task_supervisor, fn ->
        ConnectionLock.run(user_id, second_connection_id, fn ->
          send(test_pid, {:connection_lock_acquired, :second_key, self()})
          :second_done
        end)
      end)

    assert_receive {:connection_lock_acquired, :second_key, _second_pid}
    assert :second_done = Task.await(second_task)
    send(first_pid, :release_connection_lock)
    assert :first_done = Task.await(first_task)
  end

  test "serializes a multi-transaction operation with the deletion transaction lock" do
    task_supervisor = start_supervised!(Task.Supervisor)
    user_id = System.unique_integer([:positive])
    connection_id = System.unique_integer([:positive])
    test_pid = self()

    operation_task =
      unboxed_task(task_supervisor, fn ->
        ConnectionLock.run_serialized(user_id, connection_id, fn ->
          send(test_pid, {:serialized_operation_acquired, self()})

          receive do
            :release_serialized_operation -> :operation_done
          end
        end)
      end)

    assert_receive {:serialized_operation_acquired, operation_pid}

    deletion_task =
      unboxed_task(task_supervisor, fn ->
        ConnectionLock.run(user_id, connection_id, fn ->
          send(test_pid, {:deletion_lock_acquired, self()})
          :deletion_done
        end)
      end)

    refute_receive {:deletion_lock_acquired, _deletion_pid}, 100
    send(operation_pid, :release_serialized_operation)
    assert :operation_done = Task.await(operation_task)
    assert_receive {:deletion_lock_acquired, deletion_pid}
    assert deletion_pid == deletion_task.pid
    assert :deletion_done = Task.await(deletion_task)
  end

  test "supports nested acquisition by the same process" do
    user_id = System.unique_integer([:positive])
    connection_id = System.unique_integer([:positive])

    unboxed(fn ->
      assert {:outer, :inner} =
               ConnectionLock.run(user_id, connection_id, fn ->
                 {:outer,
                  ConnectionLock.run(user_id, connection_id, fn ->
                    :inner
                  end)}
               end)

      assert :released = ConnectionLock.run(user_id, connection_id, fn -> :released end)
    end)
  end

  @tag :capture_log
  test "hands a lock to its waiter when the owner dies" do
    task_supervisor = start_supervised!(Task.Supervisor)
    user_id = System.unique_integer([:positive])
    connection_id = System.unique_integer([:positive])
    test_pid = self()

    _owner_task =
      unboxed_task(task_supervisor, fn ->
        ConnectionLock.run(user_id, connection_id, fn ->
          send(test_pid, {:dying_lock_owner_acquired, self()})

          receive do
            :never_sent -> :unreachable
          end
        end)
      end)

    assert_receive {:dying_lock_owner_acquired, owner_pid}

    waiter_task =
      unboxed_task(task_supervisor, fn ->
        ConnectionLock.run(user_id, connection_id, fn ->
          send(test_pid, {:lock_waiter_acquired, self()})
          :waiter_done
        end)
      end)

    refute Task.yield(waiter_task, 100)
    owner_ref = Process.monitor(owner_pid)
    Process.exit(owner_pid, :kill)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner_pid, :killed}
    assert_receive {:lock_waiter_acquired, waiter_pid}
    assert waiter_pid == waiter_task.pid
    assert :waiter_done = Task.await(waiter_task)
  end

  @tag :capture_log
  test "removes a dead waiter before handing the lock to the next caller" do
    task_supervisor = start_supervised!(Task.Supervisor)
    user_id = System.unique_integer([:positive])
    connection_id = System.unique_integer([:positive])
    test_pid = self()

    owner_task =
      unboxed_task(task_supervisor, fn ->
        ConnectionLock.run(user_id, connection_id, fn ->
          send(test_pid, {:queue_owner_acquired, self()})

          receive do
            :release_queue_owner -> :owner_done
          end
        end)
      end)

    assert_receive {:queue_owner_acquired, owner_pid}

    dead_waiter_task =
      unboxed_task(task_supervisor, fn ->
        send(test_pid, {:dead_waiter_attempting, self()})

        ConnectionLock.run(user_id, connection_id, fn ->
          send(test_pid, {:dead_waiter_acquired, self()})
        end)
      end)

    assert_receive {:dead_waiter_attempting, dead_waiter_pid}
    refute Task.yield(dead_waiter_task, 100)
    dead_waiter_ref = Process.monitor(dead_waiter_pid)
    Process.exit(dead_waiter_pid, :kill)
    assert_receive {:DOWN, ^dead_waiter_ref, :process, ^dead_waiter_pid, :killed}

    next_waiter_task =
      unboxed_task(task_supervisor, fn ->
        ConnectionLock.run(user_id, connection_id, fn ->
          send(test_pid, {:next_lock_waiter_acquired, self()})
          :next_waiter_done
        end)
      end)

    refute Task.yield(next_waiter_task, 100)
    send(owner_pid, :release_queue_owner)
    assert :owner_done = Task.await(owner_task)
    refute_receive {:dead_waiter_acquired, ^dead_waiter_pid}
    assert_receive {:next_lock_waiter_acquired, next_waiter_pid}
    assert next_waiter_pid == next_waiter_task.pid
    assert :next_waiter_done = Task.await(next_waiter_task)
  end

  @tag :capture_log
  test "rolls back a killed holder before the next caller acquires its key" do
    user = unboxed(fn -> AccountsFixtures.user_fixture() end)

    on_exit(fn ->
      unboxed(fn ->
        User
        |> where([stored_user], stored_user.id == ^user.id)
        |> Repo.delete_all()
      end)
    end)

    task_supervisor = start_supervised!(Task.Supervisor)
    test_pid = self()

    _holder_task =
      unboxed_task(task_supervisor, fn ->
        ConnectionLock.run(user.id, user.id, fn ->
          User
          |> where([stored_user], stored_user.id == ^user.id)
          |> Repo.update_all(set: [message_retention_days: 1])

          send(test_pid, {:lock_mutation_staged, self()})

          receive do
            :never_commit -> :unreachable
          end
        end)
      end)

    assert_receive {:lock_mutation_staged, holder_pid}
    holder_ref = Process.monitor(holder_pid)
    Process.exit(holder_pid, :kill)
    assert_receive {:DOWN, ^holder_ref, :process, ^holder_pid, :killed}

    next_task =
      unboxed_task(task_supervisor, fn ->
        ConnectionLock.run(user.id, user.id, fn ->
          Repo.get!(User, user.id).message_retention_days
        end)
      end)

    assert 3 = Task.await(next_task, 5_000)
  end

  defp unboxed(callback) do
    :ok = Sandbox.checkout(Repo, sandbox: false)

    try do
      callback.()
    after
      :ok = Sandbox.checkin(Repo)
    end
  end

  defp unboxed_task(supervisor, callback) do
    Task.Supervisor.async_nolink(supervisor, fn ->
      :ok = Sandbox.checkout(Repo, sandbox: false)

      try do
        callback.()
      after
        :ok = Sandbox.checkin(Repo)
      end
    end)
  end
end
