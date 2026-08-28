defmodule TopicsClub.Chat.Connections do
  @moduledoc false

  import Ecto.Query

  alias TopicsClub.Accounts.User

  alias TopicsClub.Chat.{
    ConnectionAttributes,
    ConnectionEndpoint,
    ConnectionSnapshot,
    ServerConnection
  }

  alias TopicsClub.EngineClient
  alias TopicsClub.Repo

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
    user
    |> get!(id)
    |> ServerConnection.changeset(ConnectionAttributes.normalize_host(attrs))
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
end
