defmodule IrcpipeWeb.UserChannel.SessionAuthorization do
  @moduledoc false

  alias Ircpipe.Accounts
  alias Ircpipe.Accounts.UserToken

  def authorized?(socket, user_id) do
    with true <- Integer.to_string(socket.assigns.current_user.id) == user_id,
         token when is_binary(token) <- socket.assigns[:session_token],
         {user, _inserted_at} <- Accounts.get_user_by_session_token(token) do
      user.id == socket.assigns.current_user.id
    else
      _result -> false
    end
  end

  def schedule_expiration(socket) do
    expires_at =
      socket.assigns[:session_token_inserted_at]
      |> Kernel.||(DateTime.utc_now(:second))
      |> UserToken.session_token_expires_at()

    delay = max(DateTime.diff(expires_at, DateTime.utc_now(:millisecond), :millisecond), 0)
    Process.send_after(self(), :validate_auth_session, delay)
  end
end
