defmodule Ircpipe.Chat.ConnectionLifecycle do
  @moduledoc false

  alias Ircpipe.Chat.{ServerConnection, ServerConnectionLock}
  alias Ircpipe.Realtime.Event
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
      connection.id
      |> ServerConnectionLock.lock_active!()
      |> ServerConnection.changeset(%{nickname: nickname})
      |> update_or_rollback()
    end)
    |> tap(fn
      {:ok, updated} -> broadcast_status(updated, status || updated.status)
      _other -> :ok
    end)
  end

  def broadcast_status(%ServerConnection{} = connection, status) do
    assert_no_outer_transaction!()

    case ServerConnectionLock.serialize_effects(connection.id, fn active_connection ->
           Phoenix.PubSub.broadcast(
             Ircpipe.PubSub,
             "user:#{active_connection.user_id}",
             {:server_status, Event.server_status(active_connection, status)}
           )
         end) do
      {:ok, :ok} -> :ok
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
