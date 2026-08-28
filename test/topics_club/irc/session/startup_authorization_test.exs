defmodule TopicsClub.Irc.Session.StartupAuthorizationTest do
  use TopicsClub.DataCase, async: false

  alias TopicsClub.AccountsFixtures
  alias TopicsClub.Chat
  alias TopicsClub.Chat.Connections
  alias TopicsClub.Irc.Session.StartupAuthorization
  alias TopicsClub.Repo

  test "loads the authoritative connection and its pending channels" do
    user = AccountsFixtures.user_fixture()

    assert {:ok, connection} =
             Connections.create(user, %{
               "name" => "startup authorization",
               "host" => "irc.startup.test",
               "nickname" => "mira"
             })

    assert {:ok, _membership} = Chat.join_channel(user, connection, "#Elixir")
    stale_request = %{connection | nickname: "stale"}

    assert {authorized, pending_channels} = StartupAuthorization.load(stale_request)
    assert authorized.id == connection.id
    assert authorized.nickname == "mira"
    assert pending_channels == MapSet.new(["#elixir"])
  end

  test "rejects a connection marked for deletion" do
    user = AccountsFixtures.user_fixture()

    assert {:ok, connection} =
             Connections.create(user, %{
               "name" => "deleting startup",
               "host" => "irc.deleting-startup.test",
               "nickname" => "mira"
             })

    connection
    |> Ecto.Changeset.change(deleting: true)
    |> Repo.update!()

    assert StartupAuthorization.load(connection) == nil
  end

  test "rejects a connection the user has paused" do
    user = AccountsFixtures.user_fixture()

    assert {:ok, connection} =
             Connections.create(user, %{
               "name" => "paused startup",
               "host" => "irc.paused-startup.test",
               "nickname" => "mira"
             })

    assert {:ok, paused} =
             connection
             |> Ecto.Changeset.change(desired_state: "paused")
             |> Repo.update()

    assert StartupAuthorization.load(paused) == {:error, :connection_paused}
  end
end
