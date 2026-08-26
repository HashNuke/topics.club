defmodule IrcpipeWeb.UserSocket do
  use Phoenix.Socket

  channel "user:*", IrcpipeWeb.UserChannel

  alias Ircpipe.Accounts

  @impl true
  def connect(_params, socket, %{session: %{"user_token" => token}}) do
    case Accounts.get_user_by_session_token(token) do
      {user, inserted_at} ->
        {:ok,
         socket
         |> assign(:current_user, user)
         |> assign(:session_token, token)
         |> assign(:session_token_inserted_at, inserted_at)
         |> assign(:session_socket_id, id_for_session_token(token))}

      _ ->
        :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(socket), do: socket.assigns.session_socket_id

  def id_for_session_token(token) when is_binary(token) do
    digest = :crypto.hash(:sha256, token) |> Base.url_encode64(padding: false)
    "user_socket:session:#{digest}"
  end
end
