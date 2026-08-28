defmodule IrcpipeWeb.AppController do
  use IrcpipeWeb, :controller

  def index(conn, _params) do
    render(conn, :index)
  end
end
