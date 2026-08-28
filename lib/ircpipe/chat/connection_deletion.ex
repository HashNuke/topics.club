defmodule Ircpipe.Chat.ConnectionDeletion do
  @moduledoc false

  import Ecto.Query

  alias Ircpipe.Accounts.User

  alias Ircpipe.Chat.{
    ConnectionDeletionBatchStore,
    ConnectionDeletionEventsWorker,
    ConnectionDeletionRequest,
    ConnectionDeletionWorker,
    ServerConnection
  }

  alias Ircpipe.Irc.ConnectionLock
  alias Ircpipe.Irc.SessionSupervisor
  alias Ircpipe.Repo

  def delete(%User{} = user, id) do
    if Repo.in_transaction?() do
      raise ArgumentError,
            "cannot delete inside an existing transaction because buffer events must follow commit"
    end

    {:ok, id} = Ecto.Type.cast(:id, id)

    case connection_for_deletion(user.id, id) do
      nil ->
        {:error, :unauthorized}

      %ServerConnection{deleting: true} = connection ->
        case resume(user.id, id) do
          :ok -> {:ok, connection}
          {:ok, _deleted} = result -> result
          {:error, _reason} = error -> error
        end

      %ServerConnection{} ->
        delete_active(user, id)
    end
  end

  defp delete_active(user, id) do
    with {:ok, {connection, _intent_job}} <- persist_deletion_intent(user, id) do
      case mark_deleting(user.id, id) do
        %ServerConnection{} = marked_connection ->
          with :ok <- maybe_pause_delete_after_mark(marked_connection) do
            case finalize(user.id, id) do
              :ok -> {:ok, marked_connection}
              result -> result
            end
          end

        :already_deleted ->
          {:ok, connection}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def finalize(user_id, id) when is_integer(user_id) and is_integer(id) do
    if Repo.in_transaction?() do
      raise ArgumentError,
            "cannot finalize deletion inside an existing transaction because buffer events must follow commit"
    end

    case deleting_connection(user_id, id) do
      nil ->
        :ok

      %ServerConnection{} ->
        with {:ok, result} <- Repo.transaction(fn -> delete_in_transaction(user_id, id) end) do
          case result do
            :already_deleted ->
              :ok

            {deleted, event_batch, event_job} ->
              maybe_pause_delete_after_commit(event_batch)

              if ConnectionDeletionEventsWorker.dispatch(event_batch.id) == :ok do
                :ok = Oban.cancel_job(Ircpipe.EngineOban, event_job)
              end

              {:ok, deleted}
          end
        end
    end
  end

  def resume(user_id, id) when is_integer(user_id) and is_integer(id) do
    case connection_for_deletion(user_id, id) do
      nil ->
        :ok

      %ServerConnection{deleting: true} ->
        finalize(user_id, id)

      %ServerConnection{} ->
        case mark_deleting(user_id, id) do
          %ServerConnection{} -> finalize(user_id, id)
          :already_deleted -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp persist_deletion_intent(user, id) do
    Repo.transaction(fn ->
      connection =
        ServerConnection
        |> where(
          [connection],
          connection.user_id == ^user.id and connection.id == ^id and not connection.deleting
        )
        |> Repo.one!()

      %ConnectionDeletionRequest{
        user_id: user.id,
        server_connection_id: connection.id
      }
      |> Repo.insert!(
        on_conflict: :nothing,
        conflict_target: [:server_connection_id]
      )

      job =
        %{user_id: user.id, connection_id: id}
        |> ConnectionDeletionWorker.new()
        |> then(&Oban.insert!(Ircpipe.EngineOban, &1))

      {connection, job}
    end)
  end

  defp mark_deleting(user_id, id) do
    ConnectionLock.run_serialized(user_id, id, fn ->
      connection =
        ServerConnection
        |> where([connection], connection.user_id == ^user_id and connection.id == ^id)
        |> Repo.one()

      case connection do
        nil ->
          :already_deleted

        %ServerConnection{deleting: true} = connection ->
          connection

        %ServerConnection{} = connection ->
          with :ok <- SessionSupervisor.stop_for_deletion(connection),
               :ok <- maybe_pause_delete_after_quiesce(connection),
               :ok <- maybe_raise_before_delete_mark(connection) do
            ConnectionLock.run(user_id, id, fn ->
              connection =
                ServerConnection
                |> where(
                  [connection],
                  connection.user_id == ^user_id and connection.id == ^id
                )
                |> Repo.one!()

              connection
              |> Ecto.Changeset.change(deleting: true)
              |> Repo.update!()
            end)
          end
      end
    end)
  end

  defp connection_for_deletion(user_id, id) do
    ServerConnection
    |> where([connection], connection.user_id == ^user_id and connection.id == ^id)
    |> Repo.one()
  end

  defp deleting_connection(user_id, id) do
    ServerConnection
    |> where(
      [connection],
      connection.user_id == ^user_id and connection.id == ^id and connection.deleting
    )
    |> Repo.one()
  end

  defp delete_in_transaction(user_id, id) do
    case ServerConnection
         |> where(
           [connection],
           connection.user_id == ^user_id and connection.id == ^id and connection.deleting
         )
         |> lock("FOR UPDATE")
         |> Repo.one() do
      nil ->
        :already_deleted

      %ServerConnection{} = connection ->
        delete_locked_connection(connection)
    end
  end

  defp delete_locked_connection(connection) do
    connection = Repo.preload(connection, :channel_memberships, force: true)
    maybe_pause_delete_after_lock(connection)
    maybe_fail_final_delete(connection)

    case Repo.delete(connection) do
      {:ok, deleted} ->
        event_batch = ConnectionDeletionBatchStore.insert!(connection)

        event_job =
          %{event_batch_id: event_batch.id}
          |> ConnectionDeletionEventsWorker.new(scheduled_in: {1, :minute})
          |> then(&Oban.insert!(Ircpipe.EngineOban, &1))

        {deleted, event_batch, event_job}

      {:error, changeset} ->
        Repo.rollback(changeset)
    end
  end

  defp maybe_pause_delete_after_quiesce(connection) do
    case Application.get_env(:ircpipe, :connection_delete_after_quiesce_barrier) do
      {test_pid, barrier_ref} when is_pid(test_pid) ->
        test_ref = Process.monitor(test_pid)
        send(test_pid, {:connection_delete_quiesced, self(), barrier_ref, connection.id})

        receive do
          {:continue_quiesced_connection_delete, ^barrier_ref} ->
            Process.demonitor(test_ref, [:flush])
            :ok

          {:DOWN, ^test_ref, :process, ^test_pid, _reason} ->
            :ok
        end

      _not_paused ->
        :ok
    end
  end

  defp maybe_raise_before_delete_mark(connection) do
    case Application.get_env(:ircpipe, :connection_before_delete_mark_exception) do
      {test_pid, exception_ref} when is_pid(test_pid) ->
        send(
          test_pid,
          {:connection_before_delete_mark_raised, self(), exception_ref, connection.id}
        )

        raise "forced pre-marker deletion exception"

      _no_exception ->
        :ok
    end
  end

  defp maybe_pause_delete_after_mark(connection) do
    case Application.get_env(:ircpipe, :connection_delete_after_mark_barrier) do
      {test_pid, barrier_ref} when is_pid(test_pid) ->
        test_ref = Process.monitor(test_pid)
        send(test_pid, {:connection_delete_marked, self(), barrier_ref, connection.id})

        receive do
          {:continue_marked_connection_delete, ^barrier_ref} ->
            Process.demonitor(test_ref, [:flush])
            :ok

          {:DOWN, ^test_ref, :process, ^test_pid, _reason} ->
            :ok
        end

      _not_paused ->
        :ok
    end
  end

  defp maybe_fail_final_delete(connection) do
    maybe_raise_final_delete(connection)

    case Application.get_env(:ircpipe, :connection_final_delete_failure) do
      {test_pid, failure_ref} when is_pid(test_pid) ->
        send(test_pid, {:connection_final_delete_failed, self(), failure_ref, connection.id})
        Repo.rollback(:forced_final_delete_failure)

      _no_failure ->
        :ok
    end
  end

  defp maybe_raise_final_delete(connection) do
    case Application.get_env(:ircpipe, :connection_final_delete_exception) do
      {test_pid, exception_ref} when is_pid(test_pid) ->
        send(test_pid, {:connection_final_delete_raised, self(), exception_ref, connection.id})
        raise "forced connection final-delete exception"

      _no_exception ->
        :ok
    end
  end

  defp maybe_pause_delete_after_commit(event_batch) do
    case Application.get_env(:ircpipe, :connection_delete_after_commit_barrier) do
      {test_pid, barrier_ref} when is_pid(test_pid) ->
        test_ref = Process.monitor(test_pid)
        send(test_pid, {:connection_delete_committed, self(), barrier_ref, event_batch.id})

        receive do
          {:continue_connection_delete_after_commit, ^barrier_ref} ->
            Process.demonitor(test_ref, [:flush])
            :ok

          {:DOWN, ^test_ref, :process, ^test_pid, _reason} ->
            :ok
        end

      _not_paused ->
        :ok
    end
  end

  defp maybe_pause_delete_after_lock(connection) do
    case Application.get_env(:ircpipe, :connection_delete_after_lock_barrier) do
      {test_pid, barrier_ref} when is_pid(test_pid) ->
        test_ref = Process.monitor(test_pid)
        send(test_pid, {:connection_delete_paused, self(), barrier_ref, connection.id})

        receive do
          {:continue_connection_delete, ^barrier_ref} ->
            Process.demonitor(test_ref, [:flush])
            :ok

          {:DOWN, ^test_ref, :process, ^test_pid, _reason} ->
            :ok
        end

      _not_paused ->
        :ok
    end
  end
end
