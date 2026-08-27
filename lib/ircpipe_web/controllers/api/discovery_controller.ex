defmodule IrcpipeWeb.Api.DiscoveryController do
  use IrcpipeWeb, :controller

  alias Ircpipe.Chat.Connections
  alias Ircpipe.Discovery
  alias Ircpipe.Irc.{Session, SessionLocator, SessionSupervisor}

  def index(conn, _params) do
    server_channels = Discovery.list_popular_server_channels()
    json(conn, %{server_channels: Enum.map(server_channels, &server_channel_json/1)})
  end

  def featured(conn, _params) do
    server_channels = Discovery.list_featured_server_channels()
    json(conn, %{server_channels: Enum.map(server_channels, &server_channel_json/1)})
  end

  def join(conn, %{"id" => id}) do
    user = conn.assigns.current_scope.user
    server_channel = Discovery.get_server_channel!(id)
    network = server_channel.network

    with {:ok, connection} <-
           Connections.create_or_get(user, %{
             "name" => network.name,
             "host" => network.host,
             "port" => network.port,
             "use_tls" => network.use_tls
           }),
         {:ok, connection} <- Connections.request_connect(user, connection.id),
         {:ok, _pid} <- SessionSupervisor.start_session(connection),
         {:ok, membership, status} <- request_join(connection, user, server_channel.name) do
      conn
      |> maybe_accept_queued(status)
      |> json(%{
        connection: connection_json(connection),
        buffer: buffer_json(connection, membership, server_channel.topic),
        status: Atom.to_string(status)
      })
    else
      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: error_reason(reason)})
    end
  rescue
    Ecto.NoResultsError ->
      conn
      |> put_status(:not_found)
      |> json(%{error: "channel_not_found"})
  end

  defp server_channel_json(server_channel) do
    %{
      id: server_channel.id,
      name: server_channel.name,
      topic: server_channel.topic,
      user_count: server_channel.user_count,
      network_id: server_channel.network.id,
      network_name: server_channel.network.name,
      server_host: server_channel.network.host,
      server_port: server_channel.network.port,
      use_tls: server_channel.network.use_tls,
      refreshed_at: server_channel.network.channels_refreshed_at
    }
  end

  defp connection_json(connection) do
    %{
      id: connection.id,
      name: connection.name,
      host: connection.host,
      port: connection.port,
      use_tls: connection.use_tls,
      nickname: connection.nickname,
      status: SessionLocator.status(connection),
      mention_notifications_enabled: connection.mention_notifications_enabled,
      notification_preference_revision: connection.notification_preference_revision
    }
  end

  defp buffer_json(connection, membership, topic) do
    %{
      buffer_id: "channel:#{membership.id}",
      buffer_type: "channel",
      server_connection_id: connection.id,
      channel_membership_id: membership.id,
      title: membership.channel,
      subtitle: topic || "on #{connection.host}",
      status: SessionLocator.status(connection),
      unread_count: membership.unread_count,
      mention_count: membership.mention_count,
      mention_notifications_enabled: membership.mention_notifications_enabled,
      notification_preference_revision: membership.notification_preference_revision
    }
  end

  defp request_join(connection, user, channel) do
    Session.request_join(connection, user, channel)
  catch
    :exit, _reason -> {:error, :not_connected}
  end

  defp maybe_accept_queued(conn, :queued), do: put_status(conn, :accepted)
  defp maybe_accept_queued(conn, :sent), do: conn

  defp error_reason(%{code: code}), do: code
  defp error_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_reason(reason), do: inspect(reason)
end
