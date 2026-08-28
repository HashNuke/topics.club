defmodule IrcpipeWeb.PageController do
  use IrcpipeWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
