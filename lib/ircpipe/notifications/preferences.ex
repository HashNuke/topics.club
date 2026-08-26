defmodule Ircpipe.Notifications.Preferences do
  import Ecto.Query

  alias Ircpipe.Accounts.Scope
  alias Ircpipe.Chat.{ChannelMembership, ServerConnection}
  alias Ircpipe.Repo

  def update_server(%Scope{user: user}, id, enabled) when is_boolean(enabled) do
    Repo.transaction(fn ->
      connection =
        ServerConnection
        |> where([connection], connection.id == ^id and connection.user_id == ^user.id)
        |> lock("FOR UPDATE")
        |> Repo.one!()

      connection
      |> Ecto.Changeset.change(
        mention_notifications_enabled: enabled,
        notification_preference_revision: connection.notification_preference_revision + 1
      )
      |> Repo.update!()
    end)
    |> unwrap_transaction()
    |> broadcast(user.id, :server)
  end

  def update_channel(%Scope{user: user}, id, enabled) when is_boolean(enabled) do
    Repo.transaction(fn ->
      candidate =
        ChannelMembership
        |> where([membership], membership.id == ^id and membership.user_id == ^user.id)
        |> Repo.one!()

      lock_server_connection!(candidate.server_connection_id)

      membership =
        ChannelMembership
        |> where([record], record.id == ^candidate.id and record.user_id == ^user.id)
        |> Repo.one!()

      membership
      |> Ecto.Changeset.change(
        mention_notifications_enabled: enabled,
        notification_preference_revision: membership.notification_preference_revision + 1
      )
      |> Repo.update!()
    end)
    |> unwrap_transaction()
    |> broadcast(user.id, :channel)
  end

  defp lock_server_connection!(server_connection_id) do
    ServerConnection
    |> where([connection], connection.id == ^server_connection_id)
    |> lock("FOR UPDATE")
    |> Repo.one!()
  end

  defp unwrap_transaction({:ok, value}), do: {:ok, value}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}

  defp broadcast({:ok, record} = result, user_id, scope) do
    payload = %{
      scope: Atom.to_string(scope),
      id: record.id,
      mention_notifications_enabled: record.mention_notifications_enabled,
      revision: record.notification_preference_revision
    }

    maybe_pause_broadcast(record)

    Phoenix.PubSub.broadcast(
      Ircpipe.PubSub,
      "user:#{user_id}",
      {:notification_preference, payload}
    )

    result
  end

  defp broadcast(result, _user_id, _scope), do: result

  defp maybe_pause_broadcast(record) do
    case Application.get_env(:ircpipe, :pause_notification_preference_broadcast) do
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
