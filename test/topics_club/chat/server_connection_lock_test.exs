defmodule TopicsClub.Chat.ServerConnectionLockTest do
  use TopicsClub.DataCase, async: true

  alias TopicsClub.AccountsFixtures
  alias TopicsClub.Chat.{Connections, ServerConnectionLock}
  alias TopicsClub.Repo

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

  test "rolls back when the locked connection is marked for deletion" do
    user = AccountsFixtures.user_fixture()

    assert {:ok, connection} =
             Connections.create(user, %{
               "name" => "deleting-row-lock-test",
               "host" => "irc.example.com",
               "nickname" => "mira"
             })

    connection
    |> Ecto.Changeset.change(deleting: true)
    |> Repo.update!()

    assert {:error, :connection_deleting} =
             Repo.transaction(fn -> ServerConnectionLock.lock_active!(connection.id) end)
  end
end
