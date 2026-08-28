defmodule TopicsClub.Chat.ConnectionCasemappingTest do
  use TopicsClub.DataCase, async: true

  alias TopicsClub.AccountsFixtures
  alias TopicsClub.Chat
  alias TopicsClub.Chat.ConnectionCasemapping
  alias TopicsClub.Chat.Connections

  test "owns connection casemapping updates without a Chat compatibility API" do
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(user, %{
        "name" => "casemapping-owner",
        "host" => "irc.casemapping-owner.test",
        "nickname" => "mira"
      })

    assert {:ok, updated_connection} = ConnectionCasemapping.update(connection, :ascii)
    assert updated_connection.casemapping == "ascii"
    assert {:module, Chat} = Code.ensure_loaded(Chat)
    refute function_exported?(Chat, :update_connection_casemapping, 2)
  end
end
