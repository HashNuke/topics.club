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

    assert_receive {:buffer_system, %{kind: "system", body: "Connecting to localhost:" <> _}},
                   1_000

    assert_receive {:irc_server_line, "NICK ircpipe"}, 1_000
    assert_receive {:irc_server_line, "USER ircpipe 0 * ircpipe"}, 1_000
    assert_receive {:buffer_system, %{kind: "system", body: "Connected to localhost."}}, 1_000
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

    assert_receive {:buffer_system, %{kind: "system", body: "Disconnected from localhost."}},
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

  test "broadcasts away state changes to joined channel buffers" do
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
             Session.handle_info(
               {:ircxd, {:away, %{nick: "akash", away?: true, message: "brb"}}},
               state
             )

    assert_receive {:presence_diff,
                    %{
                      buffer_id: buffer_id,
                      diff: %{action: "away", nick: "akash", status: "away"}
                    }}

    assert buffer_id == "channel:#{membership.id}"

    assert {:noreply, ^state} =
             Session.handle_info(
               {:ircxd, {:away, %{nick: "akash", away?: false}}},
               state
             )

    assert_receive {:presence_diff,
                    %{
                      buffer_id: ^buffer_id,
                      diff: %{action: "away", nick: "akash", status: "online"}
                    }}
  end

  test "broadcasts channel privilege mode changes as role presence diffs" do
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
             Session.handle_info(
               {:ircxd, {:mode, %{target: "#pipe", modes: "+ov", params: ["akash", "mira"]}}},
               state
             )

    assert_receive {:presence_diff,
                    %{
                      buffer_id: buffer_id,
                      diff: %{action: "role", nick: "akash", role: "op"}
                    }}

    assert_receive {:presence_diff,
                    %{
                      buffer_id: ^buffer_id,
                      diff: %{action: "role", nick: "mira", role: "voice"}
                    }}

    assert_receive {:irc_message, %{kind: "mode", body: "server set mode +ov akash mira."}}

    assert buffer_id == "channel:#{membership.id}"

    assert {:noreply, ^state} =
             Session.handle_info(
               {:ircxd,
                {:mode, %{target: "#pipe", modes: "+b-o", params: ["*!*@example.test", "akash"]}}},
               state
             )

    assert_receive {:presence_diff,
                    %{
                      buffer_id: ^buffer_id,
                      diff: %{action: "role", nick: "akash", role: "user"}
                    }}

    assert_receive {:irc_message,
                    %{kind: "mode", body: "server set mode +b-o *!*@example.test akash."}}
  end

  test "records kicks as channel system lines and removes kicked users from presence" do
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
             Session.handle_info(
               {:ircxd,
                {:kick,
                 %{
                   channel: "#pipe",
                   nick: "mira",
                   target_nick: "akash",
                   reason: "too loud"
                 }}},
               state
             )

    assert_receive {:presence_diff,
                    %{
                      buffer_id: buffer_id,
                      diff: %{action: "part", nick: "akash"}
                    }}

    assert_receive {:irc_message, %{kind: "kick", body: "akash was kicked by mira: too loud"}}

    assert buffer_id == "channel:#{membership.id}"

    assert [%{kind: "kick", body: "akash was kicked by mira: too loud"}] =
             Chat.list_messages(user, membership.id)
  end

  test "records IRC error numerics in the affected channel buffer when possible" do
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Chat.create_connection(user, %{
        "name" => "local-test",
        "host" => "localhost",
        "port" => 6667,
        "use_tls" => false,
        "nickname" => "ircpipe"
      })

    {:ok, membership} = Chat.join_channel(user, connection, "#invite")
    Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{user.id}")

    state = %{connection: connection}

    assert {:noreply, ^state} =
             Session.handle_info(
               {:ircxd,
                {:irc_error,
                 %{
                   code: "473",
                   target: "#invite",
                   reason: "Cannot join channel (+i)",
                   params: ["ircpipe", "#invite", "Cannot join channel (+i)"]
                 }}},
               state
             )

    assert_receive {:buffer_error,
                    %{
                      buffer_id: buffer_id,
                      channel_membership_id: membership_id,
                      kind: "error",
                      body: "Cannot join channel (+i)"
                    }}

    assert buffer_id == "channel:#{membership.id}"
    assert membership_id == membership.id
  end

  test "records IRC error numerics in the server buffer without a matching channel" do
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Chat.create_connection(user, %{
        "name" => "local-test",
        "host" => "localhost",
        "port" => 6667,
        "use_tls" => false,
        "nickname" => "ircpipe"
      })

    Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{user.id}")

    state = %{connection: connection}

    assert {:noreply, ^state} =
             Session.handle_info(
               {:ircxd,
                {:irc_error,
                 %{
                   code: "433",
                   target: "ircpipe",
                   reason: "Nickname is already in use",
                   params: ["ircpipe", "ircpipe", "Nickname is already in use"]
                 }}},
               state
             )

    assert_receive {:buffer_error,
                    %{
                      buffer_id: buffer_id,
                      channel_membership_id: nil,
                      kind: "error",
                      body: "Nickname is already in use"
                    }}

    assert buffer_id == "server:#{connection.id}"
  end

  test "records IRC session connection errors as server buffer errors" do
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Chat.create_connection(user, %{
        "name" => "local-test",
        "host" => "localhost",
        "port" => 6667,
        "use_tls" => false,
        "nickname" => "ircpipe"
      })

    Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{user.id}")
    state = %{connection: connection}

    assert {:noreply, ^state} =
             Session.handle_info({:ircxd, {:connect_error, :econnrefused}}, state)

    assert_receive {:buffer_error,
                    %{
                      type: "buffer:error",
                      buffer_id: buffer_id,
                      server_connection_id: connection_id,
                      channel_membership_id: nil,
                      kind: "error",
                      body: "Connection error for localhost: :econnrefused."
                    }}

    assert_receive {:server_status,
                    %{
                      type: "server:status",
                      server_connection_id: ^connection_id,
                      status: "errored"
                    }}

    assert buffer_id == "server:#{connection.id}"
    assert connection_id == connection.id
    assert Chat.get_connection!(user, connection.id).status == "errored"
  end

  test "records IRC notices, actions, topics, MOTD, and numerics in the right buffers" do
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
             Session.handle_info({:ircxd, {:welcome, %{text: "Welcome to local"}}}, state)

    assert_receive {:buffer_system, %{buffer_id: "server:" <> _, body: "Welcome to local"}}

    assert {:noreply, ^state} =
             Session.handle_info({:ircxd, {:motd, %{text: "- Be kind"}}}, state)

    assert_receive {:buffer_message, %{kind: "notice", body: "- Be kind"}}

    assert {:noreply, ^state} =
             Session.handle_info(
               {:ircxd,
                {:notice, %{target: "ircpipe", nick: "NickServ", body: "identify please"}}},
               state
             )

    assert_receive {:buffer_message,
                    %{kind: "notice", body: "NickServ: identify please", service: "NickServ"}}

    assert {:noreply, ^state} =
             Session.handle_info(
               {:ircxd,
                {:privmsg,
                 %{
                   target: "#pipe",
                   nick: "akash",
                   raw_source: "akash!user@test",
                   body: <<1, "ACTION waves", 1>>,
                   ctcp: {:ok, %Ircxd.CTCP{command: "ACTION", params: "waves"}}
                 }}},
               state
             )

    assert_receive {:irc_message,
                    %{
                      kind: "action",
                      body: "waves",
                      nick: "akash",
                      hostmask: "akash!user@test"
                    }}

    assert {:noreply, ^state} =
             Session.handle_info(
               {:ircxd, {:topic, %{channel: "#pipe", nick: "mira", topic: "new topic"}}},
               state
             )

    assert_receive {:irc_message, %{kind: "topic", body: "mira changed the topic to: new topic"}}

    channel_messages = Chat.list_messages(user, membership.id)

    assert Enum.any?(
             channel_messages,
             &(&1.kind == "action" and &1.body == "waves" and
                 &1.hostmask == "akash!user@test")
           )

    assert Enum.any?(channel_messages, &(&1.kind == "topic" and &1.body =~ "new topic"))

    server_messages = Chat.list_buffer_messages(user, "server:#{connection.id}")
    assert Enum.any?(server_messages, &(&1.body == "Welcome to local"))
    assert Enum.any?(server_messages, &(&1.kind == "notice" and &1.body == "- Be kind"))

    assert Enum.any?(
             server_messages,
             &(&1.body == "NickServ: identify please" and &1.service == "NickServ")
           )
  end

  test "rejoins persisted channel memberships after registration" do
    server = start_supervised!({IrcTestServer, self()})
    port = IrcTestServer.port(server)
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Chat.create_connection(user, %{
        "name" => "local-test-rejoin",
        "host" => "localhost",
        "port" => port,
        "use_tls" => false,
        "nickname" => "ircpipe"
      })

    {:ok, _membership} = Chat.join_channel(user, connection, "#persisted")
    connection = Chat.get_connection!(user, connection.id)

    {:ok, _pid} = SessionSupervisor.start_session(connection)

    assert_receive {:irc_server_line, "NICK ircpipe"}, 1_000
    assert_receive {:irc_server_line, "USER ircpipe 0 * ircpipe"}, 1_000
    assert_receive {:irc_server_line, "JOIN #persisted"}, 1_000

    assert :ok = Session.quit(connection)
  end
end
