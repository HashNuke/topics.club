defmodule TopicsClub.Notifications.Preferences do
  import Ecto.Query

  alias TopicsClub.Accounts.Scope
  alias TopicsClub.Chat.{ChannelMembership, ServerConnection, ServerConnectionLock}
  alias TopicsClub.Realtime.Event
  alias TopicsClub.Repo

  def update_server(%Scope{user: user}, id, enabled) when is_boolean(enabled) do
    assert_transaction_owner!()

    Repo.transaction(fn ->
      candidate =
        ServerConnection
        |> where([connection], connection.id == ^id and connection.user_id == ^user.id)
        |> Repo.one!()

      connection = ServerConnectionLock.lock_active!(candidate.id)

      connection
      |> Ecto.Changeset.change(
        mention_notifications_enabled: enabled,
        notification_preference_revision: connection.notification_preference_revision + 1
      )
      |> Repo.update!()
    end)
    |> publish(:server)
  end

  def update_channel(%Scope{user: user}, id, enabled) when is_boolean(enabled) do
    assert_transaction_owner!()

    Repo.transaction(fn ->
      candidate =
        ChannelMembership
        |> where([membership], membership.id == ^id and membership.user_id == ^user.id)
        |> Repo.one!()

      connection = ServerConnectionLock.lock_active!(candidate.server_connection_id)

      if connection.user_id != user.id do
        raise Ecto.NoResultsError, queryable: ChannelMembership
      end

      membership =
        ChannelMembership
        |> where(
          [record],
          record.id == ^candidate.id and record.user_id == ^user.id and
            record.server_connection_id == ^connection.id
        )
        |> Repo.one!()

      membership
      |> Ecto.Changeset.change(
        mention_notifications_enabled: enabled,
        notification_preference_revision: membership.notification_preference_revision + 1
      )
      |> Repo.update!()
    end)
    |> publish(:channel)
  end

  defp publish({:ok, record} = result, scope) do
    connection_id = connection_id(record, scope)

    _effects =
      ServerConnectionLock.serialize_effects(connection_id, fn connection ->
        payload = Event.notification_preference(scope, record)

        maybe_pause_broadcast(record)

        Phoenix.PubSub.broadcast(
          TopicsClub.PubSub,
          "user:#{connection.user_id}",
          {:notification_preference, payload}
        )
      end)

    result
  end

  defp publish({:error, _reason} = result, _scope), do: result

  defp connection_id(%ServerConnection{id: id}, :server), do: id

  defp connection_id(%ChannelMembership{server_connection_id: connection_id}, :channel),
    do: connection_id

  defp assert_transaction_owner! do
    if Repo.in_transaction?() do
      raise ArgumentError,
            "cannot update notification preferences inside an existing transaction"
    end
  end

  defp maybe_pause_broadcast(record) do
    case Application.get_env(:topics_club_gateway, :pause_notification_preference_broadcast) do
      {pid, revision} when is_pid(pid) and revision == record.notification_preference_revision ->
        send(pid, {:notification_preference_broadcast_paused, self(), record.id, revision})

        receive do
          {:continue_notification_preference_broadcast, ^revision} -> :ok
        end

      _other ->
        :ok
    end
  end
end
