defmodule Ircpipe.Irc.SessionTest do
  use Ircpipe.DataCase

  alias Ircpipe.AccountsFixtures
  alias Ircpipe.Chat
  alias Ircpipe.Chat.Presence
  alias Ircpipe.Chat.Connections
  alias Ircpipe.Chat.DirectMessageIngestion
  alias Ircpipe.Chat.DirectMessageLifecycle
  alias Ircpipe.Chat.MessageIngestion

  alias Ircpipe.Chat.{
    ChannelJoinRequest,
    CommandMessages,
    DirectMessageThread,
    MembershipLookup,
    MessageHistory,
    Notification
  }

  alias Ircpipe.Irc.{CommandRegistry, Session, SessionLocator, SessionSupervisor}
  alias Ircpipe.Irc.Session.PendingEchoes
  alias Ircpipe.IrcTestServer

  test "connects, joins, sends messages, and persists inbound messages" do
    server = start_supervised!({IrcTestServer, self()})
    port = IrcTestServer.port(server)
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(user, %{
        "name" => "local-test",
        "host" => "localhost",
        "port" => port,
        "use_tls" => false,
        "nickname" => "ircpipe"
      })

    {:ok, membership} = Chat.join_channel(user, connection, "#pipe")
    Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{user.id}")

    {:ok, _pid} = SessionSupervisor.start_session(connection)
    assert {:ok, _membership, _status} = Session.request_join(connection, user, "#pipe")

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

    assert {:ok, sent_message} = Session.say(connection, "#pipe", "hello from app")
    assert sent_message.body == "hello from app"
    assert_receive {:irc_server_line, "PRIVMSG #pipe :hello from app"}, 1_000

    assert :ok = IrcTestServer.broadcast(server, "#pipe", "akash", "hello ircpipe")

    assert_receive {:irc_message, %{body: "hello ircpipe", nick: "akash"}}, 1_000

    messages = MessageHistory.list_messages(user, membership.id)
    assert Enum.any?(messages, &(&1.body == "hello ircpipe" and &1.nick == "akash"))

    assert :ok = Session.quit(connection)

    assert_receive {:buffer_system, %{kind: "system", body: "Disconnected from localhost."}},
                   1_000
  end

  test "records channel system lines for IRC membership events" do
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(user, %{
        "name" => "local-test",
        "host" => "localhost",
        "port" => 6667,
        "use_tls" => false,
        "nickname" => "ircpipe"
      })

    {:ok, membership} = Chat.join_channel(user, connection, "#pipe")
    {:ok, other_membership} = Chat.join_channel(user, connection, "#other")
    Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{user.id}")

    state = %{connection: connection}

    assert {:noreply, ^state} =
             Session.handle_info({:ircxd, {:join, %{channel: "#pipe", nick: "akash"}}}, state)

    assert_receive {:irc_message, %{kind: "join", body: "akash joined #pipe."}}

    assert {:noreply, ^state} =
             Session.handle_info({:ircxd, {:part, %{channel: "#pipe", nick: "akash"}}}, state)

    assert_receive {:irc_message, %{kind: "part", body: "akash left #pipe."}}

    Presence.sync(connection, "#pipe", [%{nick: "akash", prefixes: []}])

    assert {:noreply, ^state} = Session.handle_info({:ircxd, {:quit, %{nick: "akash"}}}, state)
    assert_receive {:irc_message, %{kind: "quit", body: "akash quit."}}

    Presence.sync(connection, "#pipe", [%{nick: "akash", prefixes: []}])

    assert {:noreply, ^state} =
             Session.handle_info(
               {:ircxd, {:nick, %{old_nick: "akash", new_nick: "ak"}}},
               state
             )

    assert_receive {:irc_message, %{kind: "nick", body: "akash is now ak."}}

    assert Enum.map(MessageHistory.list_messages(user, membership.id), & &1.kind) == [
             "join",
             "part",
             "quit",
             "nick"
           ]

    assert MessageHistory.list_messages(user, other_membership.id) == []
  end

  test "consumes matching echoed channel messages from the current connection nick" do
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(user, %{
        "name" => "local-test",
        "host" => "localhost",
        "port" => 6667,
        "use_tls" => false,
        "nickname" => "mira"
      })

    {:ok, membership} = Chat.join_channel(user, connection, "#pipe")

    MessageIngestion.record_channel(connection, "#pipe", "mira", "hello from app")

    state = %{
      connection: connection,
      pending_echoes:
        PendingEchoes.new()
        |> PendingEchoes.remember("#pipe", "hello from app", "message")
    }

    assert {:noreply, updated_state} =
             Session.handle_info(
               {:ircxd,
                {:privmsg,
                 %{
                   target: "#pipe",
                   nick: "Mira",
                   raw_source: "mira!user@test",
                   body: "hello from app"
                 }}},
               state
             )

    assert [%{body: "hello from app", nick: "mira"}] =
             MessageHistory.list_messages(user, membership.id)

    assert PendingEchoes.empty?(updated_state.pending_echoes)
  end

  test "consumes self echoes using negotiated RFC1459 casemapping" do
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(user, %{
        "name" => "rfc1459-echo",
        "host" => "localhost",
        "port" => 6667,
        "use_tls" => false,
        "nickname" => "nick["
      })

    connection = connection |> Ecto.Changeset.change(casemapping: "rfc1459") |> Repo.update!()
    {:ok, membership} = Chat.join_channel(user, connection, "#pipe")

    MessageIngestion.record_channel(
      connection,
      "#pipe",
      "nick[",
      "hello from app",
      "message",
      %{direction: "outgoing"},
      :rfc1459
    )

    state = %{
      connection: connection,
      pending_echoes:
        PendingEchoes.new()
        |> PendingEchoes.remember("#pipe", "hello from app", "message")
    }

    assert {:noreply, updated_state} =
             Session.handle_info(
               {:ircxd,
                {:privmsg,
                 %{
                   target: "#pipe",
                   nick: "nick{",
                   raw_source: "nick{!user@test",
                   body: "hello from app"
                 }}},
               state
             )

    assert [%{body: "hello from app", nick: "nick["}] =
             MessageHistory.list_messages(user, membership.id)

    assert PendingEchoes.empty?(updated_state.pending_echoes)
    assert Repo.reload(membership).unread_count == 0
  end

  test "classifies an overflowed same-nick channel echo as outgoing attention-free traffic" do
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(user, %{
        "name" => "local-test",
        "host" => "localhost",
        "port" => 6667,
        "use_tls" => false,
        "nickname" => "mira"
      })

    {:ok, membership} = Chat.join_channel(user, connection, "#pipe")
    body = "message delayed past the pending cap"

    MessageIngestion.record_channel(
      connection,
      "#pipe",
      "mira",
      body,
      "message",
      %{direction: "outgoing"}
    )

    state = %{
      connection: connection,
      pending_echoes:
        Enum.reduce(1..200, PendingEchoes.new(), fn index, pending_echoes ->
          PendingEchoes.remember(
            pending_echoes,
            "#pipe",
            "newer #{index}",
            "message"
          )
        end)
    }

    assert {:noreply, _updated_state} =
             Session.handle_info(
               {:ircxd,
                {:privmsg,
                 %{
                   target: "#pipe",
                   nick: "Mira",
                   raw_source: "mira!user@test",
                   body: body
                 }}},
               state
             )

    messages = MessageHistory.list_messages(user, membership.id)
    assert Enum.count(messages, &(&1.body == body)) == 2
    assert Enum.all?(messages, &(not &1.mentioned))
    assert Repo.reload(membership).unread_count == 0
    assert Repo.reload(membership).mention_count == 0
    assert Repo.aggregate(Notification, :count) == 0
  end

  test "classifies an overflowed same-nick direct echo without creating self attention" do
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(user, %{
        "name" => "direct-echo-overflow",
        "host" => "localhost",
        "port" => 6667,
        "use_tls" => false,
        "nickname" => "mira"
      })

    body = "private message delayed past the pending cap"

    assert {:ok, %{thread: original_thread}} =
             DirectMessageIngestion.record(
               connection,
               "akash",
               "mira",
               body,
               "message",
               %{direction: "outgoing", peer_nick: "akash", target: "akash"}
             )

    state = %{
      connection: connection,
      pending_echoes:
        Enum.reduce(1..200, PendingEchoes.new(), fn index, pending_echoes ->
          PendingEchoes.remember(
            pending_echoes,
            "akash",
            "newer #{index}",
            "message"
          )
        end)
    }

    assert {:noreply, _updated_state} =
             Session.handle_info(
               {:ircxd,
                {:privmsg,
                 %{
                   target: "akash",
                   nick: "Mira",
                   raw_source: "mira!user@test",
                   body: body
                 }}},
               state
             )

    threads = Repo.all(DirectMessageThread)
    assert Enum.map(threads, & &1.id) == [original_thread.id]
    assert Repo.reload(original_thread).unread_count == 0
    assert Repo.aggregate(Notification, :count) == 0
  end

  test "persists direct messages and routes non-hash channel targets" do
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(user, %{
        "name" => "local-test",
        "host" => "localhost",
        "port" => 6667,
        "use_tls" => false,
        "nickname" => "mira"
      })

    {:ok, membership} = Chat.join_channel(user, connection, "&local")
    Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{user.id}")
    state = %{connection: connection, pending_echoes: PendingEchoes.new()}

    assert {:noreply, ^state} =
             Session.handle_info(
               {:ircxd,
                {:privmsg,
                 %{
                   target: "mira",
                   nick: "akash",
                   account: "akash-account",
                   raw_source: "akash!user@example.test",
                   body: "hello privately"
                 }}},
               state
             )

    assert_receive {:buffer_message,
                    %{
                      buffer_id: "direct:" <> _,
                      nick: "akash",
                      body: "hello privately",
                      metadata: %{
                        "account" => "akash-account",
                        "direction" => "incoming",
                        "peer_nick" => "akash",
                        "target" => "mira"
                      }
                    }}

    assert {:noreply, ^state} =
             Session.handle_info(
               {:ircxd,
                {:notice,
                 %{
                   target: "*",
                   nick: "irc.example.test",
                   raw_source: "irc.example.test",
                   body: "Looking up your hostname"
                 }}},
               state
             )

    assert_receive {:buffer_message,
                    %{
                      buffer_id: "server:" <> _,
                      nick: "irc.example.test",
                      body: "Looking up your hostname"
                    }}

    assert Enum.map(DirectMessageLifecycle.list(user, connection), & &1.peer_nick) == [
             "akash"
           ]

    assert {:noreply, ^state} =
             Session.handle_info(
               {:ircxd,
                {:privmsg,
                 %{
                   target: "&local",
                   nick: "akash",
                   raw_source: "akash!user@example.test",
                   body: "hello local channel"
                 }}},
               state
             )

    assert_receive {:irc_message,
                    %{
                      buffer_id: "channel:" <> _,
                      body: "hello local channel"
                    }}

    assert [%{body: "hello local channel"}] = MessageHistory.list_messages(user, membership.id)
  end

  test "accumulates IRC names chunks until names end before syncing presence" do
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(user, %{
        "name" => "local-test",
        "host" => "localhost",
        "port" => 6667,
        "use_tls" => false,
        "nickname" => "mira"
      })

    {:ok, membership} = Chat.join_channel(user, connection, "#pipe")
    Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{user.id}")

    state = %{
      connection: connection,
      pending_joins: MapSet.new(["#pipe"]),
      joined_channels: MapSet.new(),
      names_buffers: %{}
    }

    assert {:noreply, state} =
             Session.handle_info(
               {:ircxd,
                {:names,
                 %{
                   channel: "#pipe",
                   names: [
                     %{nick: "mira", prefixes: ["@"]},
                     %{nick: "akash", prefixes: []}
                   ]
                 }}},
               state
             )

    refute_receive {:presence_sync, _payload}, 100

    assert {:noreply, state} =
             Session.handle_info(
               {:ircxd,
                {:names,
                 %{
                   channel: "#pipe",
                   names: [
                     %{nick: "sam", prefixes: ["+"]},
                     %{nick: "zoe", prefixes: []}
                   ]
                 }}},
               state
             )

    refute_receive {:presence_sync, _payload}, 100

    assert {:noreply, state} =
             Session.handle_info({:ircxd, {:names_end, %{channel: "#pipe"}}}, state)

    assert_receive {:presence_sync, %{users: users}}, 1_000
    assert Enum.map(users, & &1.nick) == ["mira", "akash", "sam", "zoe"]

    assert Enum.map(Presence.list_users(membership), & &1.nick) == [
             "akash",
             "mira",
             "sam",
             "zoe"
           ]

    assert state.names_buffers == %{}
    assert MapSet.member?(state.joined_channels, "#pipe")
    refute MapSet.member?(state.pending_joins, "#pipe")
  end

  test "broadcasts away state changes to joined channel buffers" do
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(user, %{
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
      Connections.create(user, %{
        "name" => "local-test",
        "host" => "localhost",
        "port" => 6667,
        "use_tls" => false,
        "nickname" => "ircpipe"
      })

    {:ok, membership} = Chat.join_channel(user, connection, "#pipe")
    Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{user.id}")

    state = %{
      connection: connection,
      client_info: %{
        isupport: %{
          "CHANMODES" => "beI,kfL,lj,psmntirRcOAQKVCuzNSMTGZ",
          "PREFIX" => "(ov)@+"
        }
      }
    }

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

    assert {:noreply, ^state} =
             Session.handle_info(
               {:ircxd, {:mode, %{target: "#pipe", modes: "+f-o", params: ["5:10", "akash"]}}},
               state
             )

    assert_receive {:presence_diff,
                    %{
                      buffer_id: ^buffer_id,
                      diff: %{action: "role", nick: "akash", role: "user"}
                    }}

    refute_receive {:presence_diff, %{diff: %{action: "role", nick: "5:10"}}}
  end

  test "persists and broadcasts a confirmed self nickname change" do
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(user, %{
        "name" => "local-test",
        "host" => "localhost",
        "port" => 6667,
        "use_tls" => false,
        "nickname" => "mira"
      })

    {:ok, membership} = Chat.join_channel(user, connection, "#pipe")
    Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{user.id}")
    state = %{connection: connection, client_info: nil}

    assert {:noreply, updated_state} =
             Session.handle_info(
               {:ircxd, {:nick, %{old_nick: "mira", new_nick: "mira_", source_self?: true}}},
               state
             )

    assert updated_state.connection.nickname == "mira_"
    assert Connections.get!(user, connection.id).nickname == "mira_"

    assert_receive {:server_status, %{server_connection_id: connection_id, nickname: "mira_"}}
    assert connection_id == connection.id

    assert_receive {:presence_diff,
                    %{diff: %{action: "nick", old_nick: "mira", new_nick: "mira_"}}}

    MessageIngestion.record_channel(updated_state.connection, "#pipe", "mira_", "after nick")

    assert Enum.any?(
             MessageHistory.list_messages(user, membership.id),
             &(&1.nick == "mira_" and &1.body == "after nick")
           )
  end

  test "records kicks as channel system lines and removes kicked users from presence" do
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(user, %{
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
             MessageHistory.list_messages(user, membership.id)
  end

  test "records IRC error numerics in the affected channel buffer when possible" do
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(user, %{
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
      Connections.create(user, %{
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

  test "does not treat a PART 403 as a rejected JOIN" do
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(user, %{
        "name" => "part-error",
        "host" => "localhost",
        "port" => 6667,
        "use_tls" => false,
        "nickname" => "ircpipe"
      })

    {:ok, _pending} = ChannelJoinRequest.request(user, connection, "#room")
    {:ok, membership} = Chat.confirm_channel_join(connection, "#room")
    Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{user.id}")

    state = %{
      connection: connection,
      pending_joins: MapSet.new(),
      pending_commands: %{
        "part-room" => %{command: "PART", targets: ["#room"]}
      }
    }

    assert {:noreply, ^state} =
             Session.handle_info(
               {:ircxd, {:irc_error, %{code: "403", target: "#room", reason: "No such channel"}}},
               state
             )

    unchanged = MembershipLookup.get!(user, membership.id)
    assert unchanged.status == "joined"
    assert unchanged.auto_join
    refute_receive {:buffer_left, _event}
  end

  test "part cancels an unsent queued JOIN durably" do
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(user, %{
        "name" => "cancel-queued-join",
        "host" => "localhost",
        "port" => 6667,
        "use_tls" => false,
        "nickname" => "ircpipe"
      })

    {:ok, membership} = ChannelJoinRequest.request(user, connection, "#queued")
    Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{user.id}")

    state = %{
      connection: connection,
      client: nil,
      client_info: nil,
      isupport_received?: false,
      pending_joins: MapSet.new(["#queued"]),
      sent_joins: MapSet.new(),
      joined_channels: MapSet.new()
    }

    assert {:reply, :ok, returned} =
             Session.handle_call({:part, "#queued", "leaving"}, self(), state)

    refute MapSet.member?(returned.pending_joins, "#queued")
    assert MembershipLookup.get!(user, membership.id).status == "left"
    assert_receive {:buffer_left, %{channel_membership_id: membership_id}}
    assert membership_id == membership.id
  end

  test "client-info refresh does not make a confirmed channel rejectable as a pending JOIN" do
    server = start_supervised!({IrcTestServer, self()})
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(user, %{
        "name" => "refresh-join-state",
        "host" => "localhost",
        "port" => IrcTestServer.port(server),
        "use_tls" => false,
        "nickname" => "ircpipe"
      })

    {:ok, membership} = Chat.join_channel(user, connection, "#room")
    Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{user.id}")
    on_exit(fn -> SessionSupervisor.stop_session(connection) end)
    {:ok, _pid} = SessionSupervisor.start_session(connection)

    assert_receive {:irc_server_line, "JOIN #room"}, 1_000
    {:ok, info} = Session.connection_info(connection)
    {:ok, intent} = CommandRegistry.resolve("NICK ircpipe2", info)

    assert {:ok, %{status: "sent"}} =
             Session.execute(
               connection,
               intent,
               "nick-refresh-state",
               "server:#{connection.id}"
             )

    assert_receive {:irc_server_line, "NICK ircpipe2"}, 1_000

    assert :ok =
             IrcTestServer.send_line(server, ":ircpipe-test 403 ircpipe2 #room :No such channel")

    assert_receive {:buffer_error, %{body: "No such channel"}}, 1_000

    assert MembershipLookup.get!(user, membership.id).status == "joined"
    membership_id = membership.id
    refute_receive {:buffer_left, %{channel_membership_id: ^membership_id}}
    assert :ok = Session.quit(connection)
  end

  test "removes a visible auto-join buffer when reconnect JOIN is rejected" do
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(user, %{
        "name" => "reconnect-error",
        "host" => "localhost",
        "port" => 6667,
        "use_tls" => false,
        "nickname" => "ircpipe"
      })

    {:ok, _pending} = ChannelJoinRequest.request(user, connection, "#returning")
    {:ok, membership} = Chat.confirm_channel_join(connection, "#returning")
    Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{user.id}")

    state = %{
      connection: connection,
      pending_joins: MapSet.new(["#returning"]),
      pending_commands: %{}
    }

    event =
      Ircxd.Client.Event.from_legacy!(
        {:irc_error, %{code: "473", target: "#returning", reason: "Invite only"}}
      )

    assert {:noreply, returned_state} = Session.handle_info({:ircxd, event}, state)

    refute MapSet.member?(returned_state.pending_joins, "#returning")

    assert_receive {:buffer_left,
                    %{buffer_id: "channel:" <> _, channel_membership_id: membership_id}}

    assert membership_id == membership.id
    rejected = MembershipLookup.get!(user, membership.id)
    assert rejected.status == "error"
    refute rejected.auto_join
  end

  test "records IRC session connection errors as server buffer errors" do
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(user, %{
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
    assert SessionLocator.status(connection) == "disconnected"
  end

  test "records IRC notices, actions, topics, MOTD, and numerics in the right buffers" do
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(user, %{
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
                    %{
                      kind: "notice",
                      body: "identify please",
                      nick: "NickServ",
                      service: "NickServ",
                      metadata: %{
                        "direction" => "incoming",
                        "peer_nick" => "NickServ",
                        "target" => "ircpipe"
                      }
                    }}

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

    channel_messages = MessageHistory.list_messages(user, membership.id)

    assert Enum.any?(
             channel_messages,
             &(&1.kind == "action" and &1.body == "waves" and
                 &1.hostmask == "akash!user@test")
           )

    assert Enum.any?(channel_messages, &(&1.kind == "topic" and &1.body =~ "new topic"))

    server_messages = MessageHistory.list_buffer_messages(user, "server:#{connection.id}")
    assert Enum.any?(server_messages, &(&1.body == "Welcome to local"))
    assert Enum.any?(server_messages, &(&1.kind == "notice" and &1.body == "- Be kind"))

    assert Enum.any?(
             server_messages,
             &(&1.body == "identify please" and &1.nick == "NickServ" and
                 &1.service == "NickServ")
           )
  end

  test "records a safe readable fallback for an unrecognized numeric" do
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(user, %{
        "name" => "numeric-fallback",
        "host" => "localhost",
        "port" => 6667,
        "use_tls" => false,
        "nickname" => "ircpipe"
      })

    Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{user.id}")
    state = %{connection: connection}

    message = %Ircxd.Message{
      source: "irc.example",
      command: "799",
      params: ["ircpipe", "opaque context", "A future server reply"]
    }

    assert {:noreply, ^state} = Session.handle_info({:ircxd, {:raw, message}}, state)

    assert_receive {:buffer_message,
                    %{
                      kind: "notice",
                      body: "IRC reply 799: A future server reply",
                      metadata: %{"irc_event" => "raw", "numeric" => "799"}
                    }}

    [persisted] =
      user
      |> MessageHistory.list_buffer_messages("server:#{connection.id}")
      |> Enum.filter(&(&1.body == "IRC reply 799: A future server reply"))

    assert persisted.metadata == %{"irc_event" => "raw", "numeric" => "799"}
    refute persisted.body =~ "opaque context"
  end

  test "persists canonical labeled results once and ignores the derivative batch" do
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(user, %{
        "name" => "labeled-results",
        "host" => "localhost",
        "port" => 6667,
        "use_tls" => false,
        "nickname" => "ircpipe"
      })

    buffer_id = "server:#{connection.id}"

    {:ok, invocation} =
      CommandMessages.record(connection, buffer_id, "WHOIS mira", %{
        command_id: "whois-batch-1",
        command: "WHOIS",
        command_status: "sent"
      })

    timer = Process.send_after(self(), :unused_command_timeout, 60_000)

    pending = %{
      command_id: "whois-batch-1",
      command: "WHOIS",
      invocation: invocation,
      buffer_id: buffer_id,
      spec: Ircxd.CommandSpec.get("WHOIS"),
      labeled?: true,
      timer: timer
    }

    legacy_event =
      {:labeled_response,
       %{
         label: "whois-batch-1",
         event:
           {:batch,
            %{
              events: [
                {:whois_user,
                 %{
                   nick: "mira",
                   username: "user",
                   host: "example.test",
                   realname: "Mira Example"
                 }},
                {:standard_reply,
                 %{
                   type: :note,
                   command: "WHOIS",
                   code: "CACHED",
                   context: [],
                   description: "Result served from cache."
                 }}
              ]
            }}
       }}

    event = Ircxd.Client.Event.from_legacy!(legacy_event)

    {:labeled_response, %{label: label, event: {:batch, %{events: canonical_legacy_events}}}} =
      legacy_event

    state = %{
      connection: connection,
      client: nil,
      client_info: nil,
      pending_commands: %{"whois-batch-1" => pending},
      ignored_event_logs: %{}
    }

    returned_state =
      Enum.reduce(canonical_legacy_events, state, fn legacy_event, current_state ->
        canonical_event = %{Ircxd.Client.Event.from_legacy!(legacy_event) | label: label}

        assert {:noreply, next_state} =
                 Session.handle_info({:ircxd, canonical_event}, current_state)

        next_state
      end)

    assert {:noreply, returned_state} = Session.handle_info({:ircxd, event}, returned_state)
    Process.cancel_timer(timer)

    assert returned_state.pending_commands == state.pending_commands

    results =
      user
      |> MessageHistory.list_buffer_messages(buffer_id)
      |> Enum.filter(&(&1.metadata["command_status"] == "result"))

    assert length(results) == 2

    assert Enum.all?(results, &(&1.metadata["command_id"] == "whois-batch-1"))
    assert Enum.any?(results, &(&1.metadata["irc_event"] == "whois_user"))

    assert Enum.any?(results, fn result ->
             result.metadata["irc_event"] == "standard_reply" and
               result.body =~ "description=Result served from cache."
           end)
  end

  test "persists each result from a real labeled-response batch exactly once" do
    server = start_supervised!({IrcTestServer, {self(), labeled_responses?: true}})
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(user, %{
        "name" => "labeled-pipeline",
        "host" => "localhost",
        "port" => IrcTestServer.port(server),
        "use_tls" => false,
        "nickname" => "ircpipe"
      })

    Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{user.id}")
    {:ok, _pid} = SessionSupervisor.start_session(connection)

    assert_receive {:irc_server_line, "NICK ircpipe"}, 1_000
    assert_receive {:irc_server_line, "USER ircpipe 0 * ircpipe"}, 1_000
    assert_receive {:buffer_system, %{body: "Connected to localhost."}}, 1_000
    _ = :sys.get_state(SessionLocator.via(connection))

    {:ok, client_info} = Session.connection_info(connection)
    {:ok, intent} = CommandRegistry.resolve("WHOIS mira", client_info)
    command_id = "whois-real-batch-1"
    buffer_id = "server:#{connection.id}"

    assert {:ok, %{status: "sent"}} =
             Session.execute(connection, intent, command_id, buffer_id)

    expected_line = "@label=#{command_id} WHOIS mira"
    assert_receive {:irc_server_line, ^expected_line}, 1_000

    assert_receive {:buffer_system,
                    %{
                      metadata: %{
                        "command_id" => ^command_id,
                        "command_status" => "result"
                      }
                    }},
                   1_000

    assert_receive {:buffer_system,
                    %{
                      metadata: %{
                        "command_id" => ^command_id,
                        "command_status" => "result"
                      }
                    }},
                   1_000

    assert_receive {:buffer_system,
                    %{
                      metadata: %{
                        "command_id" => ^command_id,
                        "command_status" => "completed"
                      }
                    }},
                   1_000

    _ = :sys.get_state(SessionLocator.via(connection))

    results =
      user
      |> MessageHistory.list_buffer_messages(buffer_id)
      |> Enum.filter(fn message ->
        message.metadata["command_id"] == command_id and
          message.metadata["command_status"] == "result"
      end)

    assert length(results) == 2

    assert Enum.sort(Enum.map(results, & &1.metadata["irc_event"])) == [
             "standard_reply",
             "whois_user"
           ]

    assert :ok = Session.quit(connection)
  end

  test "fails only the unlabeled query matched by standard reply context" do
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(user, %{
        "name" => "standard-fail-correlation",
        "host" => "localhost",
        "port" => 6667,
        "use_tls" => false,
        "nickname" => "ircpipe"
      })

    buffer_id = "server:#{connection.id}"

    {:ok, alice_invocation} =
      CommandMessages.record(connection, buffer_id, "WHOIS alice", %{
        command_id: "whois-alice",
        command: "WHOIS",
        command_status: "sent"
      })

    {:ok, bob_invocation} =
      CommandMessages.record(connection, buffer_id, "WHOIS bob", %{
        command_id: "whois-bob",
        command: "WHOIS",
        command_status: "sent"
      })

    alice_timer = Process.send_after(self(), :unused_alice_timeout, 60_000)
    bob_timer = Process.send_after(self(), :unused_bob_timeout, 60_000)
    spec = Ircxd.CommandSpec.get("WHOIS")

    state = %{
      connection: connection,
      client: nil,
      client_info: nil,
      pending_commands: %{
        "whois-alice" => %{
          command_id: "whois-alice",
          command: "WHOIS",
          targets: ["alice"],
          invocation: alice_invocation,
          buffer_id: buffer_id,
          spec: spec,
          labeled?: false,
          timer: alice_timer
        },
        "whois-bob" => %{
          command_id: "whois-bob",
          command: "WHOIS",
          targets: ["bob"],
          invocation: bob_invocation,
          buffer_id: buffer_id,
          spec: spec,
          labeled?: false,
          timer: bob_timer
        }
      },
      ignored_event_logs: %{}
    }

    event =
      Ircxd.Client.Event.from_legacy!(
        {:standard_reply,
         %{
           type: :fail,
           command: "WHOIS",
           code: "NO_SUCH_NICK",
           context: ["bob"],
           description: "No such nick"
         }}
      )

    assert {:noreply, returned_state} = Session.handle_info({:ircxd, event}, state)
    assert Map.has_key?(returned_state.pending_commands, "whois-alice")
    refute Map.has_key?(returned_state.pending_commands, "whois-bob")

    assert Repo.get!(Ircpipe.Chat.Message, alice_invocation.id).metadata["command_status"] ==
             "sent"

    assert Repo.get!(Ircpipe.Chat.Message, bob_invocation.id).metadata["command_status"] ==
             "failed"

    Process.cancel_timer(alice_timer)
  end

  test "does not complete an unlabeled JOIN from another user's event and rejects its failure" do
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(user, %{
        "name" => "join-correlation",
        "host" => "localhost",
        "port" => 6667,
        "use_tls" => false,
        "nickname" => "ircpipe"
      })

    {:ok, membership} = ChannelJoinRequest.request(user, connection, "#wanted")
    buffer_id = "server:#{connection.id}"
    Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{user.id}")

    {:ok, invocation} =
      CommandMessages.record(connection, buffer_id, "JOIN #wanted", %{
        command_id: "join-wanted-1",
        command: "JOIN",
        command_status: "sent"
      })

    timer = Process.send_after(self(), :unused_join_timeout, 60_000)
    spec = Ircxd.CommandSpec.classify("JOIN", ["#wanted"], %{isupport: %{}})

    {:ok, nick_invocation} =
      CommandMessages.record(connection, buffer_id, "NICK ircpipe_", %{
        command_id: "nick-self-1",
        command: "NICK",
        command_status: "sent"
      })

    nick_timer = Process.send_after(self(), :unused_nick_timeout, 60_000)
    nick_spec = Ircxd.CommandSpec.classify("NICK", ["ircpipe_"], %{isupport: %{}})

    pending = %{
      command_id: "join-wanted-1",
      command: "JOIN",
      targets: ["#wanted"],
      invocation: invocation,
      buffer_id: buffer_id,
      spec: Map.put(spec, :terminal_events, [:join]),
      labeled?: false,
      timer: timer
    }

    nick_pending = %{
      command_id: "nick-self-1",
      command: "NICK",
      targets: ["ircpipe_"],
      invocation: nick_invocation,
      buffer_id: buffer_id,
      spec: Map.put(nick_spec, :terminal_events, [:nick]),
      labeled?: false,
      timer: nick_timer
    }

    state = %{
      connection: connection,
      client: nil,
      client_info: nil,
      joined_channels: MapSet.new(),
      pending_joins: MapSet.new(["#wanted"]),
      pending_commands: %{"join-wanted-1" => pending, "nick-self-1" => nick_pending},
      ignored_event_logs: %{}
    }

    unrelated_join =
      Ircxd.Client.Event.from_legacy!(
        {:join,
         %{
           channel: "#wanted",
           nick: "someone-else",
           source_self?: false
         }}
      )

    assert {:noreply, state} = Session.handle_info({:ircxd, unrelated_join}, state)
    assert Map.has_key?(state.pending_commands, "join-wanted-1")
    assert MembershipLookup.get!(user, membership.id).status == "pending"

    unrelated_nick =
      Ircxd.Client.Event.from_legacy!(
        {:nick,
         %{
           old_nick: "someone-else",
           new_nick: "someone-new",
           source_self?: false
         }}
      )

    assert {:noreply, state} = Session.handle_info({:ircxd, unrelated_nick}, state)
    assert Map.has_key?(state.pending_commands, "nick-self-1")

    unrelated_need_more_params =
      Ircxd.Client.Event.from_legacy!(
        {:irc_error,
         %{
           code: "461",
           target: "WHO",
           reason: "Not enough parameters"
         }}
      )

    assert {:noreply, state} =
             Session.handle_info({:ircxd, unrelated_need_more_params}, state)

    assert Map.has_key?(state.pending_commands, "join-wanted-1")
    assert MapSet.member?(state.pending_joins, "#wanted")
    assert MembershipLookup.get!(user, membership.id).status == "pending"

    join_error =
      Ircxd.Client.Event.from_legacy!(
        {:irc_error,
         %{
           code: "403",
           target: "#wanted",
           reason: "No such channel"
         }}
      )

    assert {:noreply, failed_state} = Session.handle_info({:ircxd, join_error}, state)
    refute Map.has_key?(failed_state.pending_commands, "join-wanted-1")
    refute MapSet.member?(failed_state.pending_joins, "#wanted")

    assert_receive {:buffer_left, %{buffer_id: "channel:" <> _}}

    rejected = MembershipLookup.get!(user, membership.id)
    assert rejected.status == "error"
    refute rejected.auto_join

    failed_invocation = Ircpipe.Repo.get!(Ircpipe.Chat.Message, invocation.id)
    assert failed_invocation.metadata["command_status"] == "failed"
    Process.cancel_timer(nick_timer)
  end

  test "recomputes pre-005 self identity with the stored ASCII casemapping" do
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(user, %{
        "name" => "ascii-self-identity",
        "host" => "localhost",
        "port" => 6667,
        "use_tls" => false,
        "nickname" => "Nick["
      })

    {:ok, connection} = Chat.update_connection_casemapping(connection, :ascii)
    {:ok, membership} = ChannelJoinRequest.request(user, connection, "#room", :ascii)

    state = %{
      connection: connection,
      client_info: nil,
      isupport_received?: false,
      pending_joins: MapSet.new(["#room"]),
      joined_channels: MapSet.new(),
      sent_joins: MapSet.new(),
      pending_commands: %{},
      names_buffers: %{}
    }

    assert {:noreply, returned} =
             Session.handle_info(
               {:ircxd,
                {:join, %{channel: "#room", nick: "Nick{", source_self?: true, account: nil}}},
               state
             )

    assert MembershipLookup.get!(user, membership.id).status == "pending"
    refute MapSet.member?(returned.joined_channels, "#room")
  end

  test "does not duplicate correlated MOTD rows through legacy handlers" do
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(user, %{
        "name" => "motd-results",
        "host" => "localhost",
        "port" => 6667,
        "use_tls" => false,
        "nickname" => "ircpipe"
      })

    buffer_id = "server:#{connection.id}"

    {:ok, invocation} =
      CommandMessages.record(connection, buffer_id, "MOTD", %{
        command_id: "motd-1",
        command: "MOTD",
        command_status: "sent"
      })

    timer = Process.send_after(self(), :unused_motd_timeout, 60_000)
    spec = Ircxd.CommandSpec.classify("MOTD", [], %{isupport: %{}})

    pending = %{
      command_id: "motd-1",
      command: "MOTD",
      targets: [],
      invocation: invocation,
      buffer_id: buffer_id,
      spec: spec,
      labeled?: false,
      timer: timer
    }

    state = %{
      connection: connection,
      client: nil,
      client_info: nil,
      pending_commands: %{"motd-1" => pending},
      ignored_event_logs: %{}
    }

    events = [
      Ircxd.Client.Event.from_legacy!({:motd_start, %{text: "Message of the day"}}),
      Ircxd.Client.Event.from_legacy!({:motd, %{text: "Be kind"}})
    ]

    returned_state =
      Enum.reduce(events, state, fn event, state ->
        assert {:noreply, state} = Session.handle_info({:ircxd, event}, state)
        state
      end)

    Process.cancel_timer(returned_state.pending_commands["motd-1"].timer)

    messages = MessageHistory.list_buffer_messages(user, buffer_id)
    results = Enum.filter(messages, &(&1.metadata["command_status"] == "result"))

    assert Enum.count(results, &(&1.body =~ "Message of the day")) == 1
    assert Enum.count(results, &(&1.body =~ "Be kind")) == 1

    refute Enum.any?(
             messages,
             &(&1.kind == "notice" and &1.body in ["Message of the day", "Be kind"])
           )
  end

  test "matches WHO nickname results when the reply channel is star" do
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(user, %{
        "name" => "who-target",
        "host" => "localhost",
        "port" => 6667,
        "use_tls" => false,
        "nickname" => "ircpipe"
      })

    buffer_id = "server:#{connection.id}"

    {:ok, invocation} =
      CommandMessages.record(connection, buffer_id, "WHO alice", %{
        command_id: "who-alice-1",
        command: "WHO",
        command_status: "sent"
      })

    timer = Process.send_after(self(), :unused_who_timeout, 60_000)

    pending = %{
      command_id: "who-alice-1",
      command: "WHO",
      targets: ["alice"],
      invocation: invocation,
      buffer_id: buffer_id,
      spec: Ircxd.CommandSpec.classify("WHO", ["alice"], %{isupport: %{}}),
      labeled?: false,
      timer: timer
    }

    state = %{
      connection: connection,
      client: nil,
      client_info: nil,
      pending_commands: %{"who-alice-1" => pending},
      ignored_event_logs: %{}
    }

    event =
      Ircxd.Client.Event.from_legacy!(
        {:who_reply,
         %{
           channel: "*",
           nick: "alice",
           username: "user",
           host: "example.test",
           realname: "Alice Example"
         }}
      )

    assert {:noreply, returned_state} = Session.handle_info({:ircxd, event}, state)
    Process.cancel_timer(returned_state.pending_commands["who-alice-1"].timer)

    assert Enum.any?(MessageHistory.list_buffer_messages(user, buffer_id), fn message ->
             message.metadata["command_id"] == "who-alice-1" and
               message.metadata["irc_event"] == "who_reply"
           end)
  end

  test "does not let an older PART intent shadow a matching JOIN event" do
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(user, %{
        "name" => "cross-family",
        "host" => "localhost",
        "port" => 6667,
        "use_tls" => false,
        "nickname" => "ircpipe"
      })

    {:ok, _membership} = Chat.join_channel(user, connection, "#same")
    buffer_id = "server:#{connection.id}"

    {:ok, part_invocation} =
      CommandMessages.record(connection, buffer_id, "PART #same", %{
        command_id: "part-same-1",
        command: "PART",
        command_status: "sent"
      })

    {:ok, join_invocation} =
      CommandMessages.record(connection, buffer_id, "JOIN #same", %{
        command_id: "join-same-1",
        command: "JOIN",
        command_status: "sent"
      })

    part_timer = Process.send_after(self(), :unused_part_timeout, 60_000)
    join_timer = Process.send_after(self(), :unused_join_timeout, 60_000)

    part_spec =
      Ircxd.CommandSpec.classify("PART", ["#same"], %{isupport: %{}})
      |> Map.put(:terminal_events, [:part])

    join_spec =
      Ircxd.CommandSpec.classify("JOIN", ["#same"], %{isupport: %{}})
      |> Map.put(:terminal_events, [:join])

    pending_commands = %{
      "part-same-1" => %{
        command_id: "part-same-1",
        command: "PART",
        targets: ["#same"],
        invocation: part_invocation,
        buffer_id: buffer_id,
        spec: part_spec,
        labeled?: false,
        timer: part_timer
      },
      "join-same-1" => %{
        command_id: "join-same-1",
        command: "JOIN",
        targets: ["#same"],
        invocation: join_invocation,
        buffer_id: buffer_id,
        spec: join_spec,
        labeled?: false,
        timer: join_timer
      }
    }

    state = %{
      connection: connection,
      client: nil,
      client_info: nil,
      joined_channels: MapSet.new(["#same"]),
      pending_commands: pending_commands,
      ignored_event_logs: %{}
    }

    event =
      Ircxd.Client.Event.from_legacy!(
        {:join, %{channel: "#same", nick: "ircpipe", source_self?: true}}
      )

    assert {:noreply, returned_state} = Session.handle_info({:ircxd, event}, state)
    refute Map.has_key?(returned_state.pending_commands, "join-same-1")
    assert Map.has_key?(returned_state.pending_commands, "part-same-1")
    Process.cancel_timer(part_timer)
  end

  test "lists advertised server channels by visible users" do
    server = start_supervised!({IrcTestServer, self()})
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(user, %{
        "name" => "directory-test",
        "host" => "localhost",
        "port" => IrcTestServer.port(server),
        "use_tls" => false,
        "nickname" => "ircpipe"
      })

    Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{user.id}")
    {:ok, _pid} = SessionSupervisor.start_session(connection)

    assert_receive {:irc_server_line, "NICK ircpipe"}, 1_000
    assert_receive {:irc_server_line, "USER ircpipe 0 * ircpipe"}, 1_000
    assert_receive {:buffer_system, %{body: "Connected to localhost."}}, 1_000

    task = Task.async(fn -> Session.list_channels(connection) end)
    assert_receive {:irc_server_line, "LIST"}, 1_000

    assert {:ok,
            [
              %{channel: "#elixir", users: 42, topic: "Elixir, OTP, and Phoenix"},
              %{channel: "#quiet", users: 4, topic: "A smaller conversation"},
              %{channel: "&local", users: 3, topic: "A local-only channel"}
            ]} = Task.await(task)

    assert :ok = Session.quit(connection)
  end

  test "rejoins persisted channel memberships after registration" do
    server = start_supervised!({IrcTestServer, self()})
    port = IrcTestServer.port(server)
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(user, %{
        "name" => "local-test-rejoin",
        "host" => "localhost",
        "port" => port,
        "use_tls" => false,
        "nickname" => "ircpipe"
      })

    {:ok, _membership} = Chat.join_channel(user, connection, "#persisted")
    connection = Connections.get!(user, connection.id)
    Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{user.id}")

    {:ok, _pid} = SessionSupervisor.start_session(connection)

    assert_receive {:irc_server_line, "NICK ircpipe"}, 1_000
    assert_receive {:irc_server_line, "USER ircpipe 0 * ircpipe"}, 1_000
    assert_receive {:irc_server_line, "JOIN #persisted"}, 1_000
    assert_receive {:presence_sync, %{buffer_id: "channel:" <> _}}, 1_000

    state = :sys.get_state(SessionLocator.via(connection))
    assert MapSet.member?(state.joined_channels, "#persisted")

    assert {:ok, _membership, _status} =
             Session.request_join(connection, user, "#persisted")

    refute_receive {:irc_server_line, "JOIN #persisted"}

    {:ok, client_info} = Session.connection_info(connection)
    {:ok, intent} = CommandRegistry.resolve("JOIN #persisted", client_info)

    assert {:error, %{code: "already_joined"}} =
             Session.execute(
               connection,
               intent,
               "join-persisted-again",
               "server:#{connection.id}"
             )

    refute_receive {:irc_server_line, "JOIN #persisted"}

    assert :ok = Session.quit(connection)
  end

  test "flushes queued joins when a server omits 005" do
    assert_queued_join_flush("no-isupport", [], "#fallback", nil)
  end

  test "waits for split ISUPPORT lines before flushing queued joins" do
    assert_queued_join_flush(
      "split-isupport",
      [
        ":ircpipe-test 005 ircpipe PREFIX=(ov)@+ :are supported",
        ":ircpipe-test 005 ircpipe CHANTYPES=~ CASEMAPPING=ascii :are supported"
      ],
      "~custom",
      "ascii"
    )
  end

  test "does not trust a partial ISUPPORT line before MOTD end" do
    server =
      start_supervised!(
        {IrcTestServer,
         {self(),
          motd_end?: false,
          isupport_lines: [":ircpipe-test 005 ircpipe PREFIX=(ov)@+ :are supported"]}}
      )

    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(user, %{
        "name" => "delayed-split-isupport",
        "host" => "localhost",
        "port" => IrcTestServer.port(server),
        "use_tls" => false,
        "nickname" => "ircpipe"
      })

    {:ok, membership} = ChannelJoinRequest.request(user, connection, "~custom", :ascii)
    Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{user.id}")
    {:ok, _pid} = SessionSupervisor.start_session(connection)
    assert_receive {:buffer_system, %{body: "Connected to localhost."}}, 1_000
    assert_receive {:irc_server_line, "JOIN ~custom"}, 1_000

    state = :sys.get_state(SessionLocator.via(connection))
    refute state.isupport_received?
    assert Connections.get!(user, connection.id).casemapping == nil
    refute MembershipLookup.get!(user, membership.id).status == "error"

    assert :ok =
             IrcTestServer.send_line(
               server,
               ":ircpipe-test 005 ircpipe CHANTYPES=~ CASEMAPPING=ascii :are supported"
             )

    assert :ok =
             IrcTestServer.send_line(server, ":ircpipe-test 376 ircpipe :End of /MOTD command")

    assert_receive {:buffer_message, %{body: "End of /MOTD command"}}, 1_000
    assert :sys.get_state(SessionLocator.via(connection)).isupport_received?
    assert Connections.get!(user, connection.id).casemapping == "ascii"
    assert :ok = Session.quit(connection)
  end

  test "accepts authoritative ISUPPORT that arrives after the fallback boundary" do
    server = start_supervised!({IrcTestServer, {self(), isupport_lines: []}})
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(user, %{
        "name" => "late-isupport",
        "host" => "localhost",
        "port" => IrcTestServer.port(server),
        "use_tls" => false,
        "nickname" => "ircpipe"
      })

    {:ok, membership} = ChannelJoinRequest.request(user, connection, "~custom", :ascii)
    Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{user.id}")
    {:ok, _pid} = SessionSupervisor.start_session(connection)
    assert_receive {:buffer_system, %{body: "Connected to localhost."}}, 1_000
    assert_receive {:irc_server_line, "JOIN ~custom"}, 1_000

    assert :ok =
             IrcTestServer.send_line(
               server,
               ":ircpipe-test 005 ircpipe CHANTYPES=~ CASEMAPPING=ascii :are supported"
             )

    _ = :sys.get_state(SessionLocator.via(connection))
    refute_receive {:irc_server_line, "JOIN ~custom"}, 200
    assert MembershipLookup.get!(user, membership.id).status == "joined"
    assert Connections.get!(user, connection.id).casemapping == "ascii"
    assert :ok = Session.quit(connection)
  end

  test "rekeys sent JOIN tracking when late ISUPPORT changes casemapping" do
    server =
      start_supervised!({IrcTestServer, {self(), isupport_lines: [], join_replies?: false}})

    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(user, %{
        "name" => "late-casemapping-rekey",
        "host" => "localhost",
        "port" => IrcTestServer.port(server),
        "use_tls" => false,
        "nickname" => "ircpipe"
      })

    {:ok, connection} = Chat.update_connection_casemapping(connection, :ascii)
    {:ok, _membership} = ChannelJoinRequest.request(user, connection, "#[room", :ascii)
    {:ok, _pid} = SessionSupervisor.start_session(connection)
    assert_receive {:irc_server_line, "JOIN #[room"}, 1_000

    assert :ok =
             IrcTestServer.send_line(
               server,
               ":ircpipe-test 005 ircpipe CHANTYPES=# CASEMAPPING=rfc1459 :are supported"
             )

    refute_receive {:irc_server_line, "JOIN #[room"}, 200
    state = :sys.get_state(SessionLocator.via(connection))
    assert MapSet.member?(state.sent_joins, ~S(#{room))
    refute MapSet.member?(state.sent_joins, "#[room")
    assert :ok = Session.quit(connection)
  end

  test "ignores a stale queued-join timer token" do
    current_token = make_ref()

    state = %{
      registered?: true,
      join_flush_timer: {make_ref(), current_token},
      marker: :unchanged
    }

    assert {:noreply, ^state} =
             Session.handle_info({:flush_pending_joins, make_ref()}, state)
  end

  test "tracks a transmitted managed JOIN and rejects a duplicate before confirmation" do
    server = start_supervised!({IrcTestServer, {self(), join_replies?: false}})
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(user, %{
        "name" => "managed-join-tracking",
        "host" => "localhost",
        "port" => IrcTestServer.port(server),
        "use_tls" => false,
        "nickname" => "ircpipe"
      })

    Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{user.id}")
    {:ok, _pid} = SessionSupervisor.start_session(connection)
    assert_receive {:buffer_system, %{body: "Connected to localhost."}}, 1_000
    {:ok, info} = Session.connection_info(connection)
    {:ok, intent} = CommandRegistry.resolve("JOIN #pending", info)

    assert {:ok, %{status: "sent"}} =
             Session.execute(connection, intent, "managed-join-1", "server:#{connection.id}")

    assert_receive {:irc_server_line, "JOIN #pending"}, 1_000

    assert {:error, %{code: "already_pending"}} =
             Session.execute(connection, intent, "managed-join-2", "server:#{connection.id}")

    assert :ok = Session.part(connection, "#pending")
    assert_receive {:irc_server_line, "PART #pending :"}, 1_000
    assert :ok = Session.quit(connection)
  end

  test "sends messages and actions to a negotiated custom channel without rewriting it" do
    server =
      start_supervised!(
        {IrcTestServer,
         {self(),
          isupport_lines: [
            ":ircpipe-test 005 ircpipe CHANTYPES=~ CASEMAPPING=ascii :are supported"
          ]}}
      )

    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(user, %{
        "name" => "custom-channel-send",
        "host" => "localhost",
        "port" => IrcTestServer.port(server),
        "use_tls" => false,
        "nickname" => "ircpipe"
      })

    {:ok, _membership} = ChannelJoinRequest.request(user, connection, "~custom", :ascii)
    Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{user.id}")
    {:ok, _pid} = SessionSupervisor.start_session(connection)
    assert_receive {:irc_server_line, "JOIN ~custom"}, 1_000
    assert_receive {:presence_sync, %{users: _users}}, 1_000

    assert {:ok, sent_message} = Session.say(connection, "~custom", "hello")
    assert sent_message.body == "hello"
    assert_receive {:irc_server_line, "PRIVMSG ~custom hello"}, 1_000

    assert {:ok, sent_action} = Session.action(connection, "~custom", "waves")
    assert sent_action.body == "waves"
    assert sent_action.kind == "action"
    action = <<1, "ACTION waves", 1>>
    assert_receive {:irc_server_line, "PRIVMSG ~custom :" <> ^action}, 1_000
    assert :ok = Session.quit(connection)
  end

  test "routes negotiated status-message targets through their underlying channel" do
    server =
      start_supervised!(
        {IrcTestServer,
         {self(),
          isupport_lines: [
            ":ircpipe-test 005 ircpipe CHANTYPES=# STATUSMSG=@+ CASEMAPPING=ascii :are supported"
          ]}}
      )

    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(user, %{
        "name" => "status-message-targets",
        "host" => "localhost",
        "port" => IrcTestServer.port(server),
        "use_tls" => false,
        "nickname" => "ircpipe"
      })

    {:ok, membership} = ChannelJoinRequest.request(user, connection, "#pipe", :ascii)
    Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{user.id}")
    {:ok, _pid} = SessionSupervisor.start_session(connection)
    assert_receive {:irc_server_line, "JOIN #pipe"}, 1_000
    _ = :sys.get_state(SessionLocator.via(connection))

    assert :ok =
             IrcTestServer.send_line(
               server,
               ":akash!user@example.test PRIVMSG @#pipe :operators only"
             )

    assert_receive {:irc_message, %{body: "operators only", buffer_id: "channel:" <> _}}, 1_000

    {:ok, info} = Session.connection_info(connection)
    {:ok, intent} = CommandRegistry.resolve("PRIVMSG +#pipe :hello voiced users", info)

    assert {:ok, %{status: "sent"}} =
             Session.execute(
               connection,
               intent,
               "status-message-command",
               "channel:#{membership.id}"
             )

    assert_receive {:irc_server_line, "PRIVMSG +#pipe :hello voiced users"}, 1_000

    messages = MessageHistory.list_messages(user, membership.id)
    assert Enum.any?(messages, &(&1.body == "operators only" and &1.nick == "akash"))
    assert Enum.any?(messages, &(&1.body == "hello voiced users" and &1.nick == "ircpipe"))
    assert DirectMessageLifecycle.list(user, connection) == []
    assert :ok = Session.quit(connection)
  end

  test "an envelope JOIN failure rejects only its correlated pending invocation" do
    Enum.each([:unlabeled_461, :labeled_461, :contextless_fail], fn scenario ->
      {user, connection, state, first, second} = two_pending_joins(scenario)

      event =
        case scenario do
          :unlabeled_461 ->
            Ircxd.Client.Event.from_legacy!(
              {:irc_error, %{code: "461", target: "JOIN", reason: "Need more params"}}
            )

          :labeled_461 ->
            event =
              Ircxd.Client.Event.from_legacy!(
                {:irc_error, %{code: "461", target: "JOIN", reason: "Need more params"}}
              )

            %{event | label: "join-b"}

          :contextless_fail ->
            Ircxd.Client.Event.from_legacy!(
              {:standard_reply,
               %{
                 type: :fail,
                 command: "JOIN",
                 code: "INVALID_PARAMS",
                 context: [],
                 description: "JOIN failed"
               }}
            )
        end

      assert {:noreply, returned} = Session.handle_info({:ircxd, event}, state)

      {failed_id, pending_id} =
        if scenario == :labeled_461, do: {second.id, first.id}, else: {first.id, second.id}

      assert Repo.get!(Ircpipe.Chat.Message, failed_id).metadata["command_status"] == "failed"
      assert Repo.get!(Ircpipe.Chat.Message, pending_id).metadata["command_status"] == "sent"

      expected_pending = if scenario == :labeled_461, do: "join-a", else: "join-b"
      assert Map.has_key?(returned.pending_commands, expected_pending)
      assert Enum.count(returned.pending_commands) == 1

      Enum.each(returned.pending_commands, fn {_id, pending} ->
        Process.cancel_timer(pending.timer)
      end)

      assert Connections.get!(user, connection.id)
    end)
  end

  test "reconciles only an unambiguous unlabeled native JOIN failure" do
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(user, %{
        "name" => "native-join-failure",
        "host" => "localhost",
        "port" => 6667,
        "use_tls" => false,
        "nickname" => "ircpipe"
      })

    {:ok, membership} = ChannelJoinRequest.request(user, connection, "#native")

    state = %{
      connection: connection,
      client: nil,
      client_info: nil,
      isupport_received?: false,
      joined_channels: MapSet.new(),
      pending_joins: MapSet.new(["#native"]),
      sent_joins: MapSet.new(["#native"]),
      pending_commands: %{},
      ignored_event_logs: %{}
    }

    event =
      Ircxd.Client.Event.from_legacy!(
        {:standard_reply,
         %{
           type: :fail,
           command: "JOIN",
           code: "INVALID_PARAMS",
           context: [],
           description: "JOIN failed"
         }}
      )

    assert {:noreply, returned} = Session.handle_info({:ircxd, event}, state)
    refute MapSet.member?(returned.pending_joins, "#native")
    assert MembershipLookup.get!(user, membership.id).status == "error"
  end

  test "does not let an unknown labeled failure reject a newer native JOIN" do
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(user, %{
        "name" => "late-labeled-join-failure",
        "host" => "localhost",
        "port" => 6667,
        "use_tls" => false,
        "nickname" => "ircpipe"
      })

    {:ok, membership} = ChannelJoinRequest.request(user, connection, "#new")

    state = %{
      connection: connection,
      client: nil,
      client_info: nil,
      isupport_received?: false,
      joined_channels: MapSet.new(),
      pending_joins: MapSet.new(["#new"]),
      sent_joins: MapSet.new(["#new"]),
      pending_commands: %{},
      ignored_event_logs: %{}
    }

    event =
      Ircxd.Client.Event.from_legacy!(
        {:standard_reply,
         %{
           type: :fail,
           command: "JOIN",
           code: "INVALID_PARAMS",
           context: ["#new"],
           description: "old JOIN failed"
         }}
      )

    assert {:noreply, returned} =
             Session.handle_info({:ircxd, %{event | label: "old-command"}}, state)

    assert MapSet.member?(returned.pending_joins, "#new")
    assert MembershipLookup.get!(user, membership.id).status == "pending"
  end

  defp two_pending_joins(scenario) do
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(user, %{
        "name" => "join-failure-#{scenario}",
        "host" => "localhost",
        "port" => 6667,
        "use_tls" => false,
        "nickname" => "ircpipe"
      })

    buffer_id = "server:#{connection.id}"

    pending =
      Map.new([{"join-a", "#a", false}, {"join-b", "#b", scenario == :labeled_461}], fn
        {command_id, target, labeled?} ->
          {:ok, invocation} =
            CommandMessages.record(connection, buffer_id, "JOIN #{target}", %{
              command_id: command_id,
              command: "JOIN",
              command_status: "sent"
            })

          timer = Process.send_after(self(), {:unused_join_timeout, command_id}, 60_000)
          spec = Ircxd.CommandSpec.classify("JOIN", [target], %{isupport: %{}})

          {command_id,
           %{
             command_id: command_id,
             command: "JOIN",
             targets: [target],
             invocation: invocation,
             buffer_id: buffer_id,
             spec: Map.put(spec, :terminal_events, [:join]),
             labeled?: labeled?,
             timer: timer
           }}
      end)

    state = %{
      connection: connection,
      client: nil,
      client_info: nil,
      isupport_received?: false,
      joined_channels: MapSet.new(),
      pending_joins: MapSet.new(["#a", "#b"]),
      pending_commands: pending,
      ignored_event_logs: %{}
    }

    {user, connection, state, pending["join-a"].invocation, pending["join-b"].invocation}
  end

  defp assert_queued_join_flush(name, lines, channel, expected_mapping) do
    server = start_supervised!({IrcTestServer, {self(), isupport_lines: lines}})
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(user, %{
        "name" => name,
        "host" => "localhost",
        "port" => IrcTestServer.port(server),
        "use_tls" => false,
        "nickname" => "ircpipe"
      })

    {:ok, _pending} = ChannelJoinRequest.request(user, connection, channel, :ascii)
    {:ok, _pid} = SessionSupervisor.start_session(connection)
    assert_receive {:irc_server_line, "JOIN " <> ^channel}, 1_000
    assert Connections.get!(user, connection.id).casemapping == expected_mapping

    state = :sys.get_state(SessionLocator.via(connection))
    assert state.isupport_received? == (lines != [])

    assert :ok = Session.quit(connection)
  end
end
