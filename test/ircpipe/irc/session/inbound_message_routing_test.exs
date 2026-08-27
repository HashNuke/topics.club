defmodule Ircpipe.Irc.Session.InboundMessageRoutingTest do
  use Ircpipe.DataCase, async: true

  alias Ircpipe.AccountsFixtures
  alias Ircpipe.Chat.{Connections, DirectMessageLifecycle}
  alias Ircpipe.Irc.Session.{InboundMessageRouting, PendingEchoes}

  test "routes a user private message into a direct-message buffer" do
    user = AccountsFixtures.user_fixture()
    connection = connection_fixture(user)
    state = %{connection: connection, pending_echoes: PendingEchoes.new()}

    payload = %{
      target: connection.nickname,
      nick: "akash",
      raw_source: "akash!user@example.test",
      body: "hello privately"
    }

    assert InboundMessageRouting.privmsg(state, payload) == state

    assert [thread] = DirectMessageLifecycle.list(user, connection)
    assert thread.peer_nick == "akash"
    assert thread.unread_count == 1
  end

  defp connection_fixture(user) do
    {:ok, connection} =
      Connections.create(user, %{
        "name" => "routing-test",
        "host" => "irc.example.com",
        "nickname" => "mira"
      })

    connection
  end
end
