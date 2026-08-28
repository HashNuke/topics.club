defmodule Ircpipe.Chat.ServerConnectionLock do
  @moduledoc false

  import Ecto.Query

  alias Ircpipe.Chat.ServerConnection
  alias Ircpipe.Repo

  @effects_lock_key {__MODULE__, :effects_lock}

  def lock!(connection_id) when is_integer(connection_id) do
    unless Repo.in_transaction?() do
      raise ArgumentError, "server connection row locks require an active database transaction"
    end

    connection_id
    |> lock_query()
    |> Repo.one!()
  end

  def lock_active!(connection_id) when is_integer(connection_id) do
    unless Repo.in_transaction?() do
      raise ArgumentError, "server connection row locks require an active database transaction"
    end

    case connection_id |> lock_query() |> Repo.one() do
      nil -> Repo.rollback(:connection_not_found)
      %ServerConnection{deleting: true} -> Repo.rollback(:connection_deleting)
      %ServerConnection{} = connection -> connection
    end
  end

  def ensure_active(connection_id) when is_integer(connection_id) do
    assert_no_outer_transaction!()

    case Repo.transaction(fn -> lock_active!(connection_id) end) do
      {:ok, %ServerConnection{}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def serialize_effects(connection_id, callback)
      when is_integer(connection_id) and is_function(callback, 1) do
    assert_no_outer_transaction!()
    maybe_pause_before_effects_lock(connection_id)

    Repo.transaction(fn ->
      connection = lock_active!(connection_id)
      previous_lock = Process.put(@effects_lock_key, connection_id)

      try do
        callback.(connection)
      after
        restore_effects_lock(previous_lock)
      end
    end)
  end

  def effects_lock_held?(connection_id) when is_integer(connection_id) do
    Process.get(@effects_lock_key) == connection_id
  end

  defp assert_no_outer_transaction! do
    if Repo.in_transaction?() do
      raise ArgumentError, "cannot acquire an owned server connection transaction"
    end
  end

  defp maybe_pause_before_effects_lock(connection_id) do
    case Application.get_env(:topics_club_core, :connection_effects_before_lock_barrier) do
      {test_pid, barrier_ref} when is_pid(test_pid) ->
        send(test_pid, {:connection_effects_paused, self(), barrier_ref, connection_id})

        receive do
          {:continue_connection_effects, ^barrier_ref} -> :ok
        end

      _not_paused ->
        :ok
    end
  end

  defp restore_effects_lock(nil), do: Process.delete(@effects_lock_key)
  defp restore_effects_lock(connection_id), do: Process.put(@effects_lock_key, connection_id)

  defp lock_query(connection_id) do
    ServerConnection
    |> where([connection], connection.id == ^connection_id)
    |> lock("FOR UPDATE")
  end
end
