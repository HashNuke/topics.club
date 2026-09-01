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
    connection = get!(user, id)

    connection
    |> ServerConnection.changeset(Map.take(attrs, @editable_fields ++ @editable_field_names))
    |> maybe_default_sasl_username(connection)
    |> maybe_increment_transport_revision(connection)
    |> Repo.update()
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
end
