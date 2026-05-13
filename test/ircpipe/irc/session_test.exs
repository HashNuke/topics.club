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

    assert_receive {:buffer_message, %{kind: "system", body: "Connecting to localhost:" <> _}},
                   1_000

    assert_receive {:irc_server_line, "NICK ircpipe"}, 1_000
    assert_receive {:irc_server_line, "USER ircpipe 0 * ircpipe"}, 1_000
    assert_receive {:buffer_message, %{kind: "system", body: "Connected to localhost."}}, 1_000
    assert_receive {:irc_server_line, "JOIN #pipe"}, 1_000

    assert_receive {:presence_sync,
                    %{
                      buffer_id: "channel:" <> _,
                      users: [
                        %{nick: "ircpipe", role: "op"},
                        %{nick: "akash", role: "user"},
                        %{nick: "mira", role: "voice"}
                      ]
                    }},
                   1_000

    assert :ok = Session.say(connection, "#pipe", "hello from app")
    assert_receive {:irc_server_line, "PRIVMSG #pipe :hello from app"}, 1_000

    assert :ok = IrcTestServer.broadcast(server, "#pipe", "akash", "hello ircpipe")

    assert_receive {:irc_message, %{body: "hello ircpipe", nick: "akash"}}, 1_000

    messages = Chat.list_messages(user, membership.id)
    assert Enum.any?(messages, &(&1.body == "hello ircpipe" and &1.nick == "akash"))

    assert :ok = Session.quit(connection)

    assert_receive {:buffer_message, %{kind: "system", body: "Disconnected from localhost."}},
                   1_000
  end

  test "records channel system lines for IRC membership events" do
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Chat.create_connection(user, %{
        "name" => "local-test",
        "host" => "localhost",
        "port" => 6667,
        "use_tls" => false,
        "nickname" => "ircpipe"
      })

    {:ok, membership} = Chat.join_channel(user, connection, "#pipe")
    Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{user.id}")

    state = %{connection: connection}

    assert {:noreply, ^state} =
             Session.handle_info({:ircxd, {:join, %{channel: "#pipe", nick: "akash"}}}, state)

    assert_receive {:irc_message, %{kind: "join", body: "akash joined #pipe."}}

    assert {:noreply, ^state} =
             Session.handle_info({:ircxd, {:part, %{channel: "#pipe", nick: "akash"}}}, state)

    assert_receive {:irc_message, %{kind: "part", body: "akash left #pipe."}}

    assert {:noreply, ^state} = Session.handle_info({:ircxd, {:quit, %{nick: "akash"}}}, state)
    assert_receive {:irc_message, %{kind: "quit", body: "akash quit."}}

    assert {:noreply, ^state} =
             Session.handle_info(
               {:ircxd, {:nick, %{old_nick: "akash", new_nick: "ak"}}},
               state
             )

    assert_receive {:irc_message, %{kind: "nick", body: "akash is now ak."}}

    assert Enum.map(Chat.list_messages(user, membership.id), & &1.kind) == [
             "join",
             "part",
             "quit",
             "nick"
           ]
  end
end
