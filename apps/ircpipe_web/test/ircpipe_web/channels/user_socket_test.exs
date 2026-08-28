defmodule IrcpipeWeb.UserSocketTest do
  use IrcpipeWeb.ChannelCase

  alias Ircpipe.Accounts
  alias Ircpipe.AccountsFixtures
  alias IrcpipeWeb.UserSocket

  test "binds each browser socket to its exact authenticated session" do
    user = AccountsFixtures.user_fixture()
    first_token = Accounts.generate_user_session_token(user)
    second_token = Accounts.generate_user_session_token(user)

    assert {:ok, first_socket} =
             UserSocket.connect(%{}, socket(UserSocket, "first", %{}), %{
               session: %{"user_token" => first_token}
             })

    assert {:ok, second_socket} =
             UserSocket.connect(%{}, socket(UserSocket, "second", %{}), %{
               session: %{"user_token" => second_token}
             })

    assert UserSocket.id(first_socket) == UserSocket.id_for_session_token(first_token)
    assert UserSocket.id(second_socket) == UserSocket.id_for_session_token(second_token)
    refute UserSocket.id(first_socket) == UserSocket.id(second_socket)
  end

  test "rejects expired sessions at connect time" do
    user = AccountsFixtures.user_fixture()
    token = Accounts.generate_user_session_token(user)
    Accounts.delete_user_session_token(token)

    assert :error =
             UserSocket.connect(%{}, socket(UserSocket, "expired", %{}), %{
               session: %{"user_token" => token}
             })
  end
end
