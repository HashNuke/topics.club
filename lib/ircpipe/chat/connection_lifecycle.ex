defmodule Ircpipe.Chat.ConnectionLifecycle do
  @moduledoc false

  alias Ircpipe.Chat.{ServerConnection, ServerConnectionLock}
  alias Ircpipe.InternalEvent.Data
  alias Ircpipe.InternalEvents
  alias Ircpipe.Repo

  def update_status(%ServerConnection{} = connection, status) do
    assert_no_outer_transaction!()

    Repo.transaction(fn ->
      connection.id
      |> ServerConnectionLock.lock_active!()
      |> ServerConnection.changeset(%{
        status: status,
        last_connected_at: if(status == "connected", do: DateTime.utc_now(:second))
      })
      |> update_or_rollback()
    end)
    |> tap(fn
      {:ok, updated} -> broadcast_status(updated, updated.status)
      _other -> :ok
    end)
  end

  def touch_connected(%ServerConnection{} = connection) do
    assert_no_outer_transaction!()

    Repo.transaction(fn ->
      connection.id
      |> ServerConnectionLock.lock_active!()
      |> Ecto.Changeset.change(last_connected_at: DateTime.utc_now(:second))
      |> update_or_rollback()
    end)
  end

  def update_nickname(%ServerConnection{} = connection, nickname, status \\ nil) do
    assert_no_outer_transaction!()

    Repo.transaction(fn ->
      active_connection = ServerConnectionLock.lock_active!(connection.id)

      if active_connection.nickname == nickname do
        {:unchanged, active_connection}
      else
        updated =
          active_connection
          |> ServerConnection.changeset(%{nickname: nickname})
          |> update_or_rollback()

        {:updated, updated}
      end
    end)
    |> case do
      {:ok, {:unchanged, active_connection}} ->
        {:ok, active_connection}

      {:ok, {:updated, updated_connection}} ->
        broadcast_status(updated_connection, status || updated_connection.status)
        {:ok, updated_connection}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def broadcast_status(%ServerConnection{} = connection, status) do
    assert_no_outer_transaction!()

    case ServerConnectionLock.serialize_effects(connection.id, fn active_connection ->
           occurred_at = DateTime.utc_now(:second)

           InternalEvents.emit(
             "connection_status_changed",
             active_connection.user_id,
             %{connection: Data.connection(active_connection), status: status},
             event_id:
               "server_status:#{active_connection.id}:#{DateTime.to_unix(occurred_at, :microsecond)}",
             occurred_at: occurred_at
           )
         end) do
      {:ok, :ok} -> :ok
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp update_or_rollback(changeset) do
    case Repo.update(changeset) do
      {:ok, updated} -> updated
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp assert_no_outer_transaction! do
    if Repo.in_transaction?() do
      raise ArgumentError, "cannot mutate connection lifecycle inside an existing transaction"
    end
  end
end
