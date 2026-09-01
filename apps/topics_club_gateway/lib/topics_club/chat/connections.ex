defmodule TopicsClub.Chat.Connections do
  @moduledoc false

  import Ecto.Query

  alias TopicsClub.Accounts.User

  alias TopicsClub.Chat.{
    ConnectionEndpoint,
    ConnectionSnapshot,
    ServerConnection
  }

  alias TopicsClub.EngineClient
  alias TopicsClub.Repo

  @editable_fields ~w(port use_tls nickname server_password sasl_password)a
  @editable_field_names Enum.map(@editable_fields, &Atom.to_string/1)

  def list(%User{} = user), do: ConnectionSnapshot.list(user)

  def create(%User{} = user, attrs), do: ConnectionEndpoint.create(user, attrs)

  def create_or_get(%User{} = user, attrs), do: ConnectionEndpoint.create_or_get(user, attrs)

  def get!(%User{id: user_id}, id) do
    ServerConnection
    |> where(
      [connection],
      connection.user_id == ^user_id and connection.id == ^id and not connection.deleting
    )
    |> preload(:channel_memberships)
    |> Repo.one!()
  end

  def update(%User{} = user, id, attrs) do
    loaded_connection = get!(user, id)
    maybe_pause_after_update_load(loaded_connection)

    Repo.transaction(fn ->
      connection = get_for_update!(user, id)

      changeset =
        connection
        |> ServerConnection.changeset(Map.take(attrs, @editable_fields ++ @editable_field_names))
        |> maybe_default_sasl_username(connection)
        |> maybe_increment_transport_revision(connection)

      case Repo.update(changeset) do
        {:ok, updated} -> updated
        {:error, %Ecto.Changeset{} = changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  def delete(%User{} = user, id) do
    if Repo.in_transaction?() do
      raise ArgumentError,
            "cannot delete inside an existing transaction because buffer events must follow commit"
    end

    connection = get!(user, id)

    case EngineClient.delete_connection(user.id, connection.id) do
      {:ok, %{deleted: true}} -> {:ok, connection}
      {:error, error} -> {:error, error}
    end
  end

  defp maybe_increment_transport_revision(changeset, connection) do
    if map_size(changeset.changes) > 0 do
      Ecto.Changeset.put_change(
        changeset,
        :transport_revision,
        connection.transport_revision + 1
      )
    else
      changeset
    end
  end

  defp maybe_default_sasl_username(changeset, connection) do
    password = Ecto.Changeset.get_field(changeset, :sasl_password)

    if blank?(connection.sasl_username) and not blank?(password) do
      Ecto.Changeset.put_change(
        changeset,
        :sasl_username,
        Ecto.Changeset.get_field(changeset, :nickname)
      )
    else
      changeset
    end
  end

  defp blank?(value), do: not is_binary(value) or String.trim(value) == ""

  defp get_for_update!(%User{id: user_id}, id) do
    ServerConnection
    |> where(
      [connection],
      connection.user_id == ^user_id and connection.id == ^id and not connection.deleting
    )
    |> lock("FOR UPDATE")
    |> preload(:channel_memberships)
    |> Repo.one!()
  end

  defp maybe_pause_after_update_load(connection) do
    case Application.get_env(:topics_club_gateway, :connection_update_after_load_barrier) do
      {test_pid, barrier_ref} when is_pid(test_pid) and is_reference(barrier_ref) ->
        send(
          test_pid,
          {:connection_update_loaded, self(), barrier_ref, connection.id,
           connection.transport_revision}
        )

        receive do
          {:continue_connection_update, ^barrier_ref} -> :ok
        end

      _other ->
        :ok
    end
  end
end
