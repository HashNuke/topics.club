defmodule TopicsClubWeb.Api.ConnectionController do
  use TopicsClubWeb, :controller

  alias TopicsClub.Chat.Connections
  alias TopicsClub.EngineClient
  alias TopicsClub.Realtime.Event
  alias TopicsClubWeb.Api.EngineErrorResponse
  alias TopicsClubWeb.EngineStatuses

  def index(conn, _params) do
    user = conn.assigns.current_scope.user
    connections = Connections.list(user)
    statuses = EngineStatuses.fetch(user, connections)

    json(conn, %{
      connections: Enum.map(connections, &connection_json(&1, EngineStatuses.get(statuses, &1)))
    })
  end

  def create(conn, %{"connection" => attrs}) do
    user = conn.assigns.current_scope.user

    with {:ok, connection} <- Connections.create_or_get(user, attrs),
         {:ok, %{status: status}} <- EngineClient.ensure_connection(user.id, connection.id) do
      conn
      |> put_status(if(connection.inserted_at == connection.updated_at, do: :created, else: :ok))
      |> json(%{
        connection: connection_json(%{connection | channel_memberships: []}, status)
      })
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        validation_error(conn, changeset)

      {:error, %{code: _code} = error} ->
        EngineErrorResponse.respond(conn, error)
    end
  end

  def update(conn, %{"id" => id, "connection" => attrs}) do
    user = conn.assigns.current_scope.user
    previous = Connections.get!(user, id)

    with {:ok, connection} <- Connections.update(user, id, attrs),
         {:ok, status} <- apply_transport_update(user, previous, connection) do
      json(conn, %{connection: connection_json(connection, status)})
    else
      {:error, %Ecto.Changeset{} = changeset} -> validation_error(conn, changeset)
      {:error, %{code: _code} = error} -> EngineErrorResponse.respond(conn, error)
    end
  end

  def connect(conn, %{"id" => id}) do
    user = conn.assigns.current_scope.user
    connection = Connections.get!(user, id)

    with {:ok, %{status: status}} <- EngineClient.ensure_connection(user.id, connection.id) do
      json(conn, %{connection: connection_json(connection, status)})
    else
      {:error, %{code: _code} = error} -> EngineErrorResponse.respond(conn, error)
    end
  end

  def disconnect(conn, %{"id" => id}) do
    user = conn.assigns.current_scope.user
    connection = Connections.get!(user, id)

    with {:ok, %{status: status}} <-
           EngineClient.disconnect_connection(user.id, connection.id) do
      json(conn, %{connection: connection_json(connection, status)})
    else
      {:error, %{code: _code} = error} -> EngineErrorResponse.respond(conn, error)
    end
  end

  def delete(conn, %{"id" => id}) do
    user = conn.assigns.current_scope.user
    connection = Connections.get!(user, id)

    with {:ok, %{deleted: true}} <- EngineClient.delete_connection(user.id, connection.id) do
      json(conn, %{deleted: Event.server_deleted(connection)})
    else
      {:error, %{code: _code} = error} -> EngineErrorResponse.respond(conn, error)
    end
  end

  defp connection_json(connection, status) do
    %{
      id: connection.id,
      name: connection.name,
      host: connection.host,
      port: connection.port,
      use_tls: connection.use_tls,
      nickname: connection.nickname,
      status: status,
      mention_notifications_enabled: connection.mention_notifications_enabled,
      notification_preference_revision: connection.notification_preference_revision,
      channels:
        Enum.map(
          (Ecto.assoc_loaded?(connection.channel_memberships) && connection.channel_memberships) ||
            [],
          &channel_json/1
        )
    }
  end

  defp apply_transport_update(user, previous, connection) do
    if connection.transport_revision != previous.transport_revision and
         connection.desired_state == "connected" do
      case EngineClient.reconnect_connection(user.id, connection.id, reason: "settings changed") do
        {:ok, %{status: status}} -> {:ok, status}
        {:error, error} -> {:error, error}
      end
    else
      {:ok, EngineStatuses.one(user, connection)}
    end
  end

  defp channel_json(channel) do
    %{
      id: channel.id,
      channel: channel.channel,
      unread_count: channel.unread_count,
      mention_count: channel.mention_count,
      mention_notifications_enabled: channel.mention_notifications_enabled,
      notification_preference_revision: channel.notification_preference_revision
    }
  end

  defp validation_error(conn, changeset) do
    errors =
      Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
        Regex.replace(~r"%{(\w+)}", message, fn _, key ->
          opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
        end)
      end)

    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "invalid_connection", errors: errors})
  end
end
