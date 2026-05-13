defmodule Ircpipe.Irc.SessionTest do
  use Ircpipe.DataCase

  alias Ircpipe.AccountsFixtures
  alias Ircpipe.Chat
  alias Ircpipe.Irc.{Session, SessionSupervisor}
  alias Ircpipe.IrcTestServer

  test "connects, joins, sends messages, and persists inbound messages" do
    server = start_supervised!({IrcTestServer, self()})
    port = IrcTestServer.port(server)
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Chat.create_connection(user, %{
        "name" => "local-test",
        "host" => "localhost",
        "port" => port,
        "use_tls" => false,
        "nickname" => "ircpipe"
      })

    {:ok, membership} = Chat.join_channel(user, connection, "#pipe")
    Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{user.id}")

    {:ok, _pid} = SessionSupervisor.start_session(connection)
    assert :ok = Session.join(connection, "#pipe")

    assert_receive {:irc_server_line, "NICK ircpipe"}, 1_000
    assert_receive {:irc_server_line, "USER ircpipe 0 * :ircpipe"}, 1_000
    assert_receive {:irc_server_line, "JOIN #pipe"}, 1_000

    assert :ok = Session.say(connection, "#pipe", "hello from app")
    assert_receive {:irc_server_line, "PRIVMSG #pipe :hello from app"}, 1_000

    assert :ok = IrcTestServer.broadcast(server, "#pipe", "akash", "hello ircpipe")

    assert_receive {:irc_message, %{body: "hello ircpipe", nick: "akash"}}, 1_000

    messages = Chat.list_messages(user, membership.id)
    assert Enum.any?(messages, &(&1.body == "hello ircpipe" and &1.nick == "akash"))
  end
end
