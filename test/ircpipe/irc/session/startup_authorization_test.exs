defmodule Ircpipe.Irc.Session.StartupAuthorizationTest do
  use Ircpipe.DataCase, async: false

  alias Ircpipe.AccountsFixtures
  alias Ircpipe.Chat
  alias Ircpipe.Chat.Connections
  alias Ircpipe.Irc.Session.StartupAuthorization
  alias Ircpipe.Repo

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

    assert {:ok, paused} = Connections.request_disconnect(user, connection.id)
    assert StartupAuthorization.load(paused) == {:error, :connection_paused}
  end
end
