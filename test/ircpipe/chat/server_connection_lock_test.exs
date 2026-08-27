defmodule Ircpipe.Chat.ServerConnectionLockTest do
  use Ircpipe.DataCase, async: true

  alias Ircpipe.AccountsFixtures
  alias Ircpipe.Chat.{Connections, ServerConnectionLock}
  alias Ircpipe.Repo

  test "requires and works inside an explicit transaction" do
    user = AccountsFixtures.user_fixture()

    assert {:ok, connection} =
             Connections.create(user, %{
               "name" => "row-lock-test",
               "host" => "irc.example.com",
               "nickname" => "mira"
             })

    assert_raise ArgumentError, ~r/active database transaction/, fn ->
      ServerConnectionLock.lock!(connection.id)
    end

    assert {:ok, locked} = Repo.transaction(fn -> ServerConnectionLock.lock!(connection.id) end)
    assert locked.id == connection.id
  end
end
