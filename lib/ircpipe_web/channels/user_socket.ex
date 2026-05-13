defmodule IrcpipeWeb.UserSocket do
  use Phoenix.Socket

  channel "user:*", IrcpipeWeb.UserChannel

  alias Ircpipe.Accounts

  @impl true
  def connect(_params, socket, %{session: %{"user_token" => token}}) do
    case Accounts.get_user_by_session_token(token) do
      {user, _inserted_at} -> {:ok, assign(socket, :current_user, user)}
      _ -> :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(socket), do: "user_socket:#{socket.assigns.current_user.id}"
end
