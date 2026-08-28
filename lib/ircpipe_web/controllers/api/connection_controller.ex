defmodule IrcpipeWeb.Api.ConnectionController do
  use IrcpipeWeb, :controller

  alias Ircpipe.Chat.Connections
  alias Ircpipe.EngineClient
  alias Ircpipe.Realtime.Event
  alias IrcpipeWeb.Api.EngineErrorResponse
  alias IrcpipeWeb.EngineStatuses

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

    with {:ok, connection} <- Connections.update(user, id, attrs) do
      json(conn, %{connection: connection_json(connection, EngineStatuses.one(user, connection))})
    else
      {:error, %Ecto.Changeset{} = changeset} -> validation_error(conn, changeset)
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

    {:ok, _connection} = Connections.delete(user, id)

    json(conn, %{deleted: Event.server_deleted(connection)})
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
