defmodule TopicsClubWeb.PageController do
  use TopicsClubWeb, :controller

  alias TopicsClub.Discovery
  alias TopicsClubWeb.Api.ServerChannelJSON

  def home(conn, _params) do
    featured_channels =
      Discovery.list_featured_server_channels()
      |> Enum.map(&ServerChannelJSON.render/1)

    render(conn, :home, featured_channels: featured_channels)
  end
end
