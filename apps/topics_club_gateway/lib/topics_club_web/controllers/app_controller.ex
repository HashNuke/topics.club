defmodule TopicsClubWeb.AppController do
  use TopicsClubWeb, :controller

  def index(conn, _params) do
    render(conn, :index)
  end
end
