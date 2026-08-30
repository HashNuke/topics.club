defmodule TopicsClubWeb.Api.ServerChannelJSON do
  @moduledoc false

  def render(server_channel) do
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
end
