defmodule Ircpipe.Chat.DirectMessageRenamerTest do
  use Ircpipe.DataCase, async: true

  alias Ircpipe.AccountsFixtures

  alias Ircpipe.Chat.{
    Connections,
    DirectMessageLifecycle,
    DirectMessageRenamer
  }

  test "renames an existing peer while preserving its thread identity" do
    user = AccountsFixtures.user_fixture()
    connection = connection_fixture(user)
    {:ok, thread} = DirectMessageLifecycle.open(user, connection, "akash")

    assert {:ok, renamed} =
             DirectMessageRenamer.rename(
               connection,
               "akash",
               "mira",
               %{account: "account-a", hostmask: "mira!a@example.test"},
               :rfc1459
             )

    assert renamed.id == thread.id
    assert renamed.peer_nick == "mira"
    assert renamed.peer_key == "mira"
    assert renamed.account == "account-a"
    assert renamed.hostmask == "mira!a@example.test"
  end

  defp connection_fixture(user) do
    {:ok, connection} =
      Connections.create(user, %{
        "name" => "renamer-test",
        "host" => "irc.example.com",
        "nickname" => "local"
      })

    connection
  end
end
