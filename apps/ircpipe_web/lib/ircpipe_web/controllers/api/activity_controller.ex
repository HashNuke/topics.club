defmodule IrcpipeWeb.Api.ActivityController do
  use IrcpipeWeb, :controller

  def create(conn, _params) do
    json(conn, %{ok: true, server_time: DateTime.utc_now(:second)})
  end
end
