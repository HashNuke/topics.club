defmodule TopicsClubWeb.Api.DiscoveryController do
  use TopicsClubWeb, :controller

  alias TopicsClub.Chat.Connections
  alias TopicsClub.Discovery
  alias TopicsClub.EngineClient
  alias TopicsClubWeb.Api.EngineErrorResponse
  alias TopicsClubWeb.Api.ServerChannelJSON

  def index(conn, params) do
    page =
      case Integer.parse(Map.get(params, "page", "1")) do
        {value, ""} when value > 0 -> value
        _invalid -> 1
      end

    directory =
      Discovery.paginate_server_channels(
        page: page,
        search: Map.get(params, "query", "")
      )

    json(conn, %{
      page: directory.page,
      page_size: directory.page_size,
      query: directory.query,
      server_channels: Enum.map(directory.server_channels, &ServerChannelJSON.render/1),
      total_channels: directory.total_channels,
      total_pages: directory.total_pages
    })
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
         {:ok, %{membership: membership, status: status, connection_status: connection_status}} <-
           EngineClient.join_channel(user.id, connection.id, server_channel.name) do
      conn
      |> maybe_accept_queued(status)
      |> json(%{
        connection: connection_json(connection, connection_status),
        buffer: buffer_json(connection, membership, server_channel.topic, connection_status),
        status: status
      })
    else
      {:error, %{code: _code} = error} ->
        EngineErrorResponse.respond(conn, error)

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
      notification_preference_revision: connection.notification_preference_revision
    }
  end

  defp buffer_json(connection, membership, topic, status) do
    %{
      buffer_id: "channel:#{membership.id}",
      buffer_type: "channel",
      server_connection_id: connection.id,
      channel_membership_id: membership.id,
      title: membership.channel,
      subtitle: topic || "on #{connection.host}",
      status: status,
      unread_count: membership.unread_count,
      mention_count: membership.mention_count,
      mention_notifications_enabled: membership.mention_notifications_enabled,
      notification_preference_revision: membership.notification_preference_revision
    }
  end

  defp maybe_accept_queued(conn, "queued"), do: put_status(conn, :accepted)
  defp maybe_accept_queued(conn, "sent"), do: conn

  defp error_reason(%{code: code}), do: code
  defp error_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_reason(reason), do: inspect(reason)
end
