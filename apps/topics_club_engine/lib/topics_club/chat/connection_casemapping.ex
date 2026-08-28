defmodule TopicsClub.Chat.ConnectionCasemapping do
  @moduledoc false

  alias TopicsClub.Chat.MembershipReconciler
  alias TopicsClub.Chat.ServerConnection
  alias TopicsClub.Chat.ServerConnectionLock
  alias TopicsClub.Repo

  def update(%ServerConnection{} = connection, casemapping) do
    assert_no_outer_transaction!()
    mapping = Atom.to_string(casemapping)

    Repo.transaction(fn ->
      updated_connection =
        connection.id
        |> ServerConnectionLock.lock_active!()
        |> Ecto.Changeset.change(casemapping: mapping)
        |> update_or_rollback()

      losers = MembershipReconciler.reconcile_in_transaction(updated_connection, casemapping)

      presence_sync_events =
        MembershipReconciler.presence_sync_events_in_transaction(updated_connection)

      {updated_connection, losers, presence_sync_events}
    end)
    |> case do
      {:ok, {updated_connection, losers, presence_sync_events}} ->
        MembershipReconciler.broadcast_casemapping_change(
          updated_connection,
          losers,
          presence_sync_events
        )

        {:ok, updated_connection}

      error ->
        error
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
      raise ArgumentError, "cannot update connection casemapping inside an existing transaction"
    end
  end
end
