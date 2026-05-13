defmodule IrcpipeWeb.Api.ConnectionController do
  use IrcpipeWeb, :controller

  alias Ircpipe.Chat
  alias Ircpipe.Irc.SessionSupervisor

  def index(conn, _params) do
    user = conn.assigns.current_scope.user
    json(conn, %{connections: Enum.map(Chat.list_connections(user), &connection_json/1)})
  end

  def create(conn, %{"connection" => attrs}) do
    user = conn.assigns.current_scope.user

    with {:ok, connection} <- Chat.create_or_get_connection(user, attrs) do
      SessionSupervisor.start_session(connection)

      conn
      |> put_status(if(connection.inserted_at == connection.updated_at, do: :created, else: :ok))
      |> json(%{connection: connection_json(%{connection | channel_memberships: []})})
    end
  end

  def connect(conn, %{"id" => id}) do
    user = conn.assigns.current_scope.user
    connection = Chat.get_connection!(user, id)

    with {:ok, _pid} <- SessionSupervisor.start_session(connection) do
      json(conn, %{connection: connection_json(connection)})
    end
  end

  def disconnect(conn, %{"id" => id}) do
    user = conn.assigns.current_scope.user
    connection = Chat.get_connection!(user, id)

    :ok = SessionSupervisor.stop_session(connection)
    {:ok, connection} = Chat.update_connection_status(connection, "disconnected")

    json(conn, %{connection: connection_json(connection)})
  end

  defp connection_json(connection) do
    %{
      id: connection.id,
      name: connection.name,
      host: connection.host,
      port: connection.port,
      use_tls: connection.use_tls,
      nickname: connection.nickname,
      status: connection.status,
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
      mention_count: channel.mention_count
    }
  end
end
