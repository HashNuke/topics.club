defmodule TopicsClubWeb.Api.ActivityController do
  use TopicsClubWeb, :controller

  def create(conn, _params) do
    json(conn, %{ok: true, server_time: DateTime.utc_now(:second)})
  end
end
