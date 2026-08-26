defmodule IrcpipeWeb.Api.ConnectionController do
  use IrcpipeWeb, :controller

  alias Ircpipe.Chat.Connections
  alias Ircpipe.Irc.Session
  alias Ircpipe.Irc.SessionSupervisor
  alias Ircpipe.Realtime.Event

  def index(conn, _params) do
    user = conn.assigns.current_scope.user
    json(conn, %{connections: Enum.map(Connections.list(user), &connection_json/1)})
  end

  def create(conn, %{"connection" => attrs}) do
    user = conn.assigns.current_scope.user

    with {:ok, connection} <- Connections.create_or_get(user, attrs) do
      SessionSupervisor.start_session(connection)

      conn
      |> put_status(if(connection.inserted_at == connection.updated_at, do: :created, else: :ok))
      |> json(%{connection: connection_json(%{connection | channel_memberships: []})})
    end
  end

  def update(conn, %{"id" => id, "connection" => attrs}) do
    user = conn.assigns.current_scope.user

    with {:ok, connection} <- Connections.update(user, id, attrs) do
      json(conn, %{connection: connection_json(connection)})
    end
  end

  def connect(conn, %{"id" => id}) do
    user = conn.assigns.current_scope.user
    connection = Connections.get!(user, id)

    with {:ok, _pid} <- SessionSupervisor.start_session(connection) do
      json(conn, %{connection: connection_json(connection)})
    end
  end

  def disconnect(conn, %{"id" => id}) do
    user = conn.assigns.current_scope.user
    connection = Connections.get!(user, id)

    :ok = SessionSupervisor.stop_session(connection)

    json(conn, %{connection: connection_json(connection)})
  end

  def delete(conn, %{"id" => id}) do
    user = conn.assigns.current_scope.user
    connection = Connections.get!(user, id)

    {:ok, _connection} = Connections.delete(user, id)

    json(conn, %{deleted: Event.server_deleted(connection)})
  end

  defp connection_json(connection) do
    %{
      id: connection.id,
      name: connection.name,
      host: connection.host,
      port: connection.port,
      use_tls: connection.use_tls,
      nickname: connection.nickname,
      status: Session.status(connection),
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
end
