defmodule IrcpipeWeb.UserChannelTest do
  use IrcpipeWeb.ChannelCase

  import Ecto.Query

  alias Ircpipe.AccountsFixtures
  alias Ircpipe.Accounts
  alias Ircpipe.Accounts.UserToken
  alias Ircpipe.Chat
  alias Ircpipe.Chat.ConnectionLifecycle
  alias Ircpipe.Chat.Connections
  alias Ircpipe.Chat.MessageHistory
  alias Ircpipe.Irc.Session
  alias Ircpipe.Irc.SessionSupervisor
  alias Ircpipe.IrcTestServer
  alias IrcpipeWeb.UserChannel
  alias IrcpipeWeb.UserSocket

  test "joins with server time and missed event cursor metadata" do
    user = AccountsFixtures.user_fixture()

    assert {:ok, %{server_time: server_time, missed_event_cursor: nil}, _socket} =
             authenticated_socket(user)
             |> subscribe_and_join(UserChannel, "user:#{user.id}")

    assert {:ok, _datetime, 0} = DateTime.from_iso8601(server_time)
  end

  test "disconnects a live channel when its session expires" do
    user = AccountsFixtures.user_fixture()
    socket = join_user_channel(user)
    session_socket_id = socket.assigns.session_socket_id
    session_token = socket.assigns.session_token
    IrcpipeWeb.Endpoint.subscribe(session_socket_id)

    expired_at = DateTime.utc_now(:second) |> DateTime.add(-15, :day)

    UserToken
    |> where([token], token.token == ^session_token)
    |> Ircpipe.Repo.update_all(set: [inserted_at: expired_at])

    send(socket.channel_pid, :validate_auth_session)

    assert_receive %Phoenix.Socket.Broadcast{
      topic: ^session_socket_id,
      event: "disconnect"
    }
  end

  test "suggests slash commands over the user channel" do
    user = AccountsFixtures.user_fixture()

    socket = join_user_channel(user)

    ref = push(socket, "command:suggest", %{"input" => "/jo"})

    assert_reply ref, :ok, %{
      reply: "ok",
      commands: [
        %{
          name: "/join",
          required_permission: "user",
          examples: ["/join #elixir"]
        }
      ]
    }
  end

  test "parses supported slash commands over the user channel" do
    user = AccountsFixtures.user_fixture()

    socket = join_user_channel(user)

    ref = push(socket, "command:parse", %{"input" => "/msg NickServ help"})

    assert_reply ref, :ok, %{
      reply: "ok",
      command: %{
        name: "msg",
        args: ["NickServ", "help"],
        required_permission: "user",
        examples: ["/msg NickServ help"]
      }
    }
  end

  test "rejects commands without a buffer context" do
    user = AccountsFixtures.user_fixture()
    socket = join_user_channel(user)

    ref = push(socket, "command:run", %{"input" => "/join #elixir"})

    assert_reply ref, :error, %{
      reason: "invalid_buffer",
      command_id: command_id,
      command: %{name: "join", args: ["#elixir"]}
    }

    assert is_binary(command_id)
  end

  test "runs join slash commands through the IRC session and records a server outcome" do
    server = start_supervised!({IrcTestServer, self()})
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(user, %{
        "name" => "local",
        "host" => "127.0.0.1",
        "port" => IrcTestServer.port(server),
        "use_tls" => false,
        "nickname" => "ircpipe"
      })

    socket = join_user_channel(user)
    {:ok, _pid} = SessionSupervisor.start_session(connection)

    assert_receive {:irc_server_line, "NICK ircpipe"}, 1_000
    assert_receive {:irc_server_line, "USER ircpipe 0 * ircpipe"}, 1_000
    assert_push "buffer:system", %{body: "Connected to 127.0.0.1."}

    ref =
      push(socket, "command:run", %{
        "input" => "/join #ops",
        "buffer_id" => "server:#{connection.id}"
      })

    assert_reply ref, :ok, %{command: %{name: "join", args: ["#ops"]}, buffer_id: buffer_id}
    assert_receive {:irc_server_line, "JOIN #ops"}, 1_000

    assert_push "buffer:joined", %{
      type: "buffer:joined",
      buffer: %{buffer_id: ^buffer_id, title: "#ops"}
    }

    assert_push "buffer:system", %{
      type: "buffer:system",
      buffer_id: "server:" <> _,
      kind: "command",
      body: "JOIN #ops"
    }

    assert Enum.any?(
             MessageHistory.list_buffer_messages(user, "server:#{connection.id}"),
             &(&1.kind == "command" and &1.body == "JOIN #ops")
           )

    assert :ok = Session.quit(connection)
  end

  test "runs me slash commands as channel actions" do
    server = start_supervised!({IrcTestServer, self()})
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(user, %{
        "name" => "local",
        "host" => "127.0.0.1",
        "port" => IrcTestServer.port(server),
        "use_tls" => false,
        "nickname" => "mira"
      })

    {:ok, membership} = Chat.join_channel(user, connection, "#elixir")
    {:ok, _pid} = SessionSupervisor.start_session(connection)

    assert_receive {:irc_server_line, "NICK mira"}, 1_000
    assert_receive {:irc_server_line, "USER mira 0 * mira"}, 1_000
    socket = join_user_channel(user)
    assert :ok = Session.join(connection, "#elixir")
    assert_receive {:irc_server_line, "JOIN #elixir"}, 1_000
    assert_push "presence:sync", %{buffer_id: "channel:" <> _}

    ref =
      push(socket, "command:run", %{
        "input" => "/me waves",
        "buffer_id" => "channel:#{membership.id}"
      })

    assert_reply ref, :ok, %{
      command: %{name: "me", args: ["waves"]},
      message: %{kind: "action", body: "waves", buffer_id: "channel:" <> _}
    }

    assert_receive {:irc_server_line, "PRIVMSG #elixir :\x01ACTION waves\x01"}, 1_000

    assert Enum.any?(
             MessageHistory.list_messages(user, membership.id),
             &(&1.kind == "action" and &1.body == "waves" and &1.nick == "mira")
           )

    assert :ok = Session.quit(connection)
  end

  test "runs msg commands into an auto-opened direct-message thread" do
    server = start_supervised!({IrcTestServer, self()})
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(user, %{
        "name" => "local",
        "host" => "127.0.0.1",
        "port" => IrcTestServer.port(server),
        "use_tls" => false,
        "nickname" => "mira"
      })

    socket = join_user_channel(user)
    {:ok, _pid} = SessionSupervisor.start_session(connection)
    assert_receive {:irc_server_line, "NICK mira"}, 1_000
    assert_receive {:irc_server_line, "USER mira 0 * mira"}, 1_000
    assert_push "server:status", %{status: "connected"}, 1_000
    assert {:ok, _client_info} = Session.connection_info(connection)

    ref =
      push(socket, "command:run", %{
        "input" => "/msg akash hello privately",
        "buffer_id" => "server:#{connection.id}"
      })

    assert_reply ref,
                 :ok,
                 %{
                   type: "direct_message:thread",
                   version: 1,
                   command: %{name: "msg", args: ["akash", "hello privately"]},
                   command_id: command_id,
                   connection: %{id: connection_id},
                   buffer: %{
                     buffer_id: buffer_id,
                     direct_message_thread_id: thread_id,
                     direct_message_revision: revision
                   },
                   revision: revision,
                   message: %{
                     buffer_id: message_buffer_id,
                     direct_message_thread_id: message_thread_id,
                     body: "hello privately",
                     nick: "mira"
                   }
                 },
                 1_000

    assert connection_id == connection.id
    assert "direct:" <> _ = buffer_id
    assert message_buffer_id == buffer_id
    assert message_thread_id == thread_id
    assert_receive {:irc_server_line, "PRIVMSG akash :hello privately"}, 1_000
    assert_push "direct_message:thread", %{buffer: %{buffer_id: ^buffer_id, title: "akash"}}

    server_history = MessageHistory.list_buffer_messages(user, "server:#{connection.id}")

    repair_rows =
      MessageHistory.list_buffer_command_messages(user, "server:#{connection.id}", [command_id])

    assert repair_rows != []

    refute Enum.any?(server_history ++ repair_rows, fn message ->
             String.contains?(message.body, "hello privately") or
               String.contains?(message.metadata["input"] || "", "hello privately")
           end)

    assert :ok = Session.quit(connection)
  end

  test "reads, blocks, unblocks, and closes only owned direct-message threads" do
    user = AccountsFixtures.user_fixture()
    other_user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(user, %{
        "name" => "local",
        "host" => "127.0.0.1",
        "port" => 6667,
        "use_tls" => false,
        "nickname" => "mira"
      })

    {:ok, other_connection} =
      Connections.create(other_user, %{
        "name" => "other",
        "host" => "irc.example.test",
        "port" => 6667,
        "use_tls" => false,
        "nickname" => "other"
      })

    assert {:ok, %{thread: thread}} =
             Chat.record_direct_message(
               connection,
               "akash",
               "akash",
               "ping",
               "message",
               %{direction: "incoming"}
             )

    assert {:ok, other_thread} = Chat.open_direct_message(other_user, other_connection, "private")
    socket = join_user_channel(user)
    buffer_id = "direct:#{thread.id}"

    read_ref = push(socket, "buffer:read", %{"buffer_id" => buffer_id})

    assert_reply read_ref, :ok, %{
      buffer: %{buffer_id: ^buffer_id, unread_count: 0},
      revision: read_revision
    }

    assert read_revision > thread.mutation_revision

    block_ref =
      push(socket, "direct_message:block", %{"buffer_id" => buffer_id, "blocked" => true})

    assert_reply block_ref, :ok, %{
      type: "direct_message:thread",
      version: 1,
      connection: %{id: connection_id},
      buffer: %{buffer_id: ^buffer_id, blocked: true, direct_message_revision: block_revision},
      revision: block_revision
    }

    assert connection_id == connection.id

    unblock_ref =
      push(socket, "direct_message:block", %{"buffer_id" => buffer_id, "blocked" => false})

    assert_reply unblock_ref, :ok, %{
      type: "direct_message:thread",
      version: 1,
      connection: %{id: ^connection_id},
      buffer: %{buffer_id: ^buffer_id, blocked: false, direct_message_revision: unblock_revision},
      revision: unblock_revision
    }

    close_ref = push(socket, "direct_message:close", %{"buffer_id" => buffer_id})

    assert_reply close_ref, :ok, %{
      type: "direct_message:closed",
      version: 1,
      event_id: "direct_message_closed:" <> _,
      occurred_at: %DateTime{},
      buffer_id: ^buffer_id,
      server_connection_id: ^connection_id,
      direct_message_thread_id: direct_message_thread_id,
      revision: close_revision
    }

    assert direct_message_thread_id == thread.id
    assert close_revision > unblock_revision

    foreign_ref =
      push(socket, "direct_message:close", %{"buffer_id" => "direct:#{other_thread.id}"})

    assert_reply foreign_ref, :error, %{reason: "invalid_direct_message"}
  end

  test "rejects sends through a displaced direct-message buffer" do
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(user, %{
        "name" => "local",
        "host" => "127.0.0.1",
        "port" => 6667,
        "use_tls" => false,
        "nickname" => "mira"
      })

    assert {:ok, %{thread: original}} =
             Chat.record_direct_message(
               connection,
               "alpha",
               "alpha",
               "first",
               "message",
               %{direction: "incoming", account: "account-a"}
             )

    assert {:ok, %{thread: displaced}} =
             Chat.record_direct_message(
               connection,
               "beta",
               "beta",
               "second",
               "message",
               %{direction: "incoming", account: "account-b"}
             )

    assert {:ok, renamed} =
             Chat.rename_direct_message_peer(
               connection,
               original.peer_nick,
               displaced.peer_nick,
               %{account: "account-a"},
               :rfc1459
             )

    assert renamed.id == original.id
    archived = Chat.get_direct_message_thread!(user, displaced.id)
    assert archived.closed_at
    assert String.starts_with?(archived.peer_key, "archived:")

    socket = join_user_channel(user)

    ref =
      push(socket, "message:send", %{
        "buffer_id" => "direct:#{archived.id}",
        "body" => "must not reach whoever owns beta now",
        "client_message_id" => "stale-displaced-send"
      })

    assert_reply ref, :error, %{
      reason: "direct_message_closed",
      client_message_id: "stale-displaced-send"
    }
  end

  test "rejects unknown slash commands over the user channel" do
    user = AccountsFixtures.user_fixture()
    socket = join_user_channel(user)

    ref = push(socket, "command:parse", %{"input" => "/wat"})

    assert_reply ref, :error, %{reply: "error", reason: "unknown_command", command: "wat"}
  end

  test "sends channel messages through the IRC session and replies with canonical message" do
    server = start_supervised!({IrcTestServer, self()})
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(user, %{
        "name" => "local",
        "host" => "127.0.0.1",
        "port" => IrcTestServer.port(server),
        "use_tls" => false,
        "nickname" => "mira"
      })

    {:ok, membership} = Chat.join_channel(user, connection, "#elixir")
    socket = join_user_channel(user)
    {:ok, _pid} = SessionSupervisor.start_session(connection)

    assert_receive {:irc_server_line, "NICK mira"}, 1_000
    assert_receive {:irc_server_line, "USER mira 0 * mira"}, 1_000
    assert_receive {:irc_server_line, "JOIN #elixir"}, 1_000

    assert :ok = Session.join(connection, "#elixir")
    refute_receive {:irc_server_line, "JOIN #elixir"}
    assert_push "presence:sync", %{buffer_id: "channel:" <> _}

    ref =
      push(socket, "message:send", %{
        "client_message_id" => "client-1",
        "buffer_id" => "channel:#{membership.id}",
        "body" => "hello from channel"
      })

    assert_reply ref, :ok, %{
      client_message_id: "client-1",
      message: %{
        buffer_id: "channel:" <> _,
        channel_membership_id: membership_id,
        body: "hello from channel",
        nick: "mira"
      }
    }

    assert membership_id == membership.id
    assert_receive {:irc_server_line, "PRIVMSG #elixir :hello from channel"}, 1_000

    assert Enum.any?(
             MessageHistory.list_messages(user, membership.id),
             &(&1.body == "hello from channel" and &1.nick == "mira")
           )

    dcc_body = <<1, "DCC SEND secret.txt 127001 1234 99", 1>>

    dcc_ref =
      push(socket, "message:send", %{
        "client_message_id" => "client-dcc",
        "buffer_id" => "channel:#{membership.id}",
        "body" => dcc_body
      })

    assert_reply dcc_ref, :error, %{
      reason: "unsupported_ctcp",
      client_message_id: "client-dcc"
    }

    refute_receive {:irc_server_line, "PRIVMSG #elixir :" <> ^dcc_body}

    assert :ok = Session.quit(connection)
  end

  test "broadcasts sent channel messages to every browser socket for the user" do
    server = start_supervised!({IrcTestServer, self()})
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(user, %{
        "name" => "local",
        "host" => "127.0.0.1",
        "port" => IrcTestServer.port(server),
        "use_tls" => false,
        "nickname" => "mira"
      })

    {:ok, membership} = Chat.join_channel(user, connection, "#elixir")
    {:ok, _pid} = SessionSupervisor.start_session(connection)

    assert_receive {:irc_server_line, "NICK mira"}, 1_000
    assert_receive {:irc_server_line, "USER mira 0 * mira"}, 1_000
    first_socket = join_user_channel(user)
    _second_socket = join_user_channel(user)
    assert :ok = Session.join(connection, "#elixir")
    assert_receive {:irc_server_line, "JOIN #elixir"}, 1_000
    assert_push "presence:sync", %{buffer_id: "channel:" <> _}

    ref =
      push(first_socket, "message:send", %{
        "client_message_id" => "client-broadcast",
        "buffer_id" => "channel:#{membership.id}",
        "body" => "hello every tab"
      })

    assert_reply ref, :ok, %{client_message_id: "client-broadcast"}

    assert_push "buffer:message", %{buffer_id: buffer_id, body: "hello every tab", nick: "mira"}
    assert_push "buffer:message", %{buffer_id: ^buffer_id, body: "hello every tab", nick: "mira"}

    assert buffer_id == "channel:#{membership.id}"
    assert :ok = Session.quit(connection)
  end

  test "rejects channel messages for buffers the user does not own" do
    user = AccountsFixtures.user_fixture()
    other_user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(other_user, %{
        "name" => "local",
        "host" => "127.0.0.1",
        "port" => 6667,
        "use_tls" => false,
        "nickname" => "other"
      })

    {:ok, membership} = Chat.join_channel(other_user, connection, "#private")
    socket = join_user_channel(user)

    ref =
      push(socket, "message:send", %{
        "client_message_id" => "client-2",
        "buffer_id" => "channel:#{membership.id}",
        "body" => "nope"
      })

    assert_reply ref, :error, %{reason: "invalid_buffer", client_message_id: "client-2"}
  end

  test "pushes channel buffer errors when sending fails" do
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(user, %{
        "name" => "local",
        "host" => "127.0.0.1",
        "port" => 6667,
        "use_tls" => false,
        "nickname" => "mira"
      })

    {:ok, membership} = Chat.join_channel(user, connection, "#elixir")
    socket = join_user_channel(user)

    ref =
      push(socket, "message:send", %{
        "client_message_id" => "client-failed",
        "buffer_id" => "channel:#{membership.id}",
        "body" => "this will fail"
      })

    assert_reply ref, :error, %{reason: "not_connected", client_message_id: "client-failed"}

    assert_push "buffer:error", %{
      type: "buffer:error",
      version: 1,
      event_id: "message:" <> _,
      buffer_id: buffer_id,
      server_connection_id: connection_id,
      channel_membership_id: membership_id,
      body: "Message could not be sent: not connected.",
      kind: "error"
    }

    assert buffer_id == "channel:#{membership.id}"
    assert connection_id == connection.id
    assert membership_id == membership.id
  end

  test "marks a channel buffer read over the user channel" do
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(user, %{
        "name" => "local",
        "host" => "127.0.0.1",
        "port" => 6667,
        "use_tls" => false,
        "nickname" => "mira"
      })

    {:ok, membership} = Chat.join_channel(user, connection, "#elixir")
    Chat.record_inbound_message(connection, "#elixir", "akash", "hello mira")
    socket = join_user_channel(user)

    ref = push(socket, "buffer:read", %{"buffer_id" => "channel:#{membership.id}"})

    assert_reply ref, :ok, %{
      buffer_id: "channel:" <> _,
      unread_count: 0,
      mention_count: 0
    }

    assert_push "buffer:read", %{
      type: "buffer:read",
      version: 1,
      event_id: "buffer_read:channel:" <> _,
      buffer_id: buffer_id,
      server_connection_id: connection_id,
      channel_membership_id: membership_id,
      unread_count: 0,
      mention_count: 0
    }

    assert buffer_id == "channel:#{membership.id}"
    assert connection_id == connection.id
    assert membership_id == membership.id

    reloaded = Chat.get_membership!(user, membership.id)
    assert reloaded.unread_count == 0
    assert reloaded.mention_count == 0
  end

  test "marks a server buffer read over the user channel" do
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(user, %{
        "name" => "local",
        "host" => "127.0.0.1",
        "port" => 6667,
        "use_tls" => false,
        "nickname" => "mira"
      })

    Chat.record_server_message(connection, "Connected")
    socket = join_user_channel(user)

    ref = push(socket, "buffer:read", %{"buffer_id" => "server:#{connection.id}"})

    assert_reply ref, :ok, %{
      buffer_id: "server:" <> _,
      unread_count: 0,
      mention_count: 0
    }

    assert_push "buffer:read", %{
      type: "buffer:read",
      buffer_id: buffer_id,
      server_connection_id: connection_id,
      channel_membership_id: nil,
      unread_count: 0,
      mention_count: 0
    }

    assert buffer_id == "server:#{connection.id}"
    assert connection_id == connection.id
    assert Connections.get!(user, connection.id).unread_count == 0
  end

  test "pushes server status broadcasts over the user channel" do
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(user, %{
        "name" => "local",
        "host" => "127.0.0.1",
        "port" => 6667,
        "use_tls" => false,
        "nickname" => "mira"
      })

    join_user_channel(user)

    {:ok, _connection} = ConnectionLifecycle.update_status(connection, "connected")

    assert_push "server:status", %{
      type: "server:status",
      version: 1,
      event_id: "server_status:" <> _,
      server_connection_id: connection_id,
      status: "connected"
    }

    assert connection_id == connection.id
  end

  test "syncs live IRC status when the browser channel rejoins" do
    server = start_supervised!({IrcTestServer, self()})
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(user, %{
        "name" => "local",
        "host" => "127.0.0.1",
        "port" => IrcTestServer.port(server),
        "use_tls" => false,
        "nickname" => "mira",
        "status" => "connecting"
      })

    Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{user.id}")
    {:ok, _pid} = SessionSupervisor.start_session(connection)
    assert_receive {:server_status, %{status: "connected"}}, 1_000

    join_user_channel(user)

    assert_push "server:status", %{
      server_connection_id: connection_id,
      status: "connected"
    }

    assert connection_id == connection.id
    assert :ok = Session.quit(connection)
  end

  test "pushes server buffer messages over the user channel" do
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(user, %{
        "name" => "local",
        "host" => "127.0.0.1",
        "port" => 6667,
        "use_tls" => false,
        "nickname" => "mira"
      })

    join_user_channel(user)

    Chat.record_server_message(connection, "NickServ: identify please", "notice", "NickServ", %{
      service: "NickServ"
    })

    assert_push "buffer:message", %{
      type: "buffer:message",
      version: 1,
      event_id: "message:" <> _,
      buffer_id: buffer_id,
      server_connection_id: connection_id,
      channel_membership_id: nil,
      body: "NickServ: identify please",
      kind: "notice",
      nick: "NickServ",
      service: "NickServ"
    }

    assert buffer_id == "server:#{connection.id}"
    assert connection_id == connection.id
  end

  test "pushes server buffer errors over the user channel" do
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(user, %{
        "name" => "local",
        "host" => "127.0.0.1",
        "port" => 6667,
        "use_tls" => false,
        "nickname" => "mira"
      })

    join_user_channel(user)

    Chat.record_server_message(connection, "Connection failed", "error")

    assert_push "buffer:error", %{
      type: "buffer:error",
      version: 1,
      event_id: "message:" <> _,
      buffer_id: buffer_id,
      server_connection_id: connection_id,
      body: "Connection failed",
      kind: "error"
    }

    assert buffer_id == "server:#{connection.id}"
    assert connection_id == connection.id
  end

  test "pushes server buffer system lines over the user channel" do
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(user, %{
        "name" => "local",
        "host" => "127.0.0.1",
        "port" => 6667,
        "use_tls" => false,
        "nickname" => "mira"
      })

    join_user_channel(user)

    Chat.record_server_message(connection, "Connected to local", "system")

    assert_push "buffer:system", %{
      type: "buffer:system",
      version: 1,
      event_id: "message:" <> _,
      buffer_id: buffer_id,
      server_connection_id: connection_id,
      body: "Connected to local",
      kind: "system"
    }

    assert buffer_id == "server:#{connection.id}"
    assert connection_id == connection.id
  end

  test "pushes presence sync over the user channel" do
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(user, %{
        "name" => "local",
        "host" => "127.0.0.1",
        "port" => 6667,
        "use_tls" => false,
        "nickname" => "mira"
      })

    {:ok, membership} = Chat.join_channel(user, connection, "#elixir")
    join_user_channel(user)

    Chat.broadcast_presence_sync(connection, "#elixir", [
      %{nick: "mira", prefixes: ["@"]},
      %{nick: "akash", prefixes: []}
    ])

    assert_push "presence:sync", %{
      type: "presence:sync",
      version: 1,
      event_id: "presence_sync:channel:" <> _,
      buffer_id: buffer_id,
      users: [
        %{nick: "mira", role: "op", status: "online"},
        %{nick: "akash", role: "user", status: "online"}
      ]
    }

    assert buffer_id == "channel:#{membership.id}"
  end

  test "pushes presence diffs over the user channel" do
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(user, %{
        "name" => "local",
        "host" => "127.0.0.1",
        "port" => 6667,
        "use_tls" => false,
        "nickname" => "mira"
      })

    {:ok, membership} = Chat.join_channel(user, connection, "#elixir")
    join_user_channel(user)

    Chat.broadcast_presence_diff(connection, "#elixir", %{
      action: "join",
      user: %{nick: "akash", role: "user", status: "online"}
    })

    assert_push "presence:diff", %{
      type: "presence:diff",
      version: 1,
      event_id: "presence_diff:channel:" <> _,
      buffer_id: buffer_id,
      diff: %{action: "join", user: %{nick: "akash", role: "user", status: "online"}}
    }

    assert buffer_id == "channel:#{membership.id}"
  end

  test "pushes away presence diffs over the user channel" do
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(user, %{
        "name" => "local",
        "host" => "127.0.0.1",
        "port" => 6667,
        "use_tls" => false,
        "nickname" => "mira"
      })

    {:ok, membership} = Chat.join_channel(user, connection, "#elixir")
    join_user_channel(user)

    Chat.broadcast_presence_diff(connection, "#elixir", %{
      action: "away",
      nick: "akash",
      status: "away"
    })

    assert_push "presence:diff", %{
      type: "presence:diff",
      version: 1,
      event_id: "presence_diff:channel:" <> _,
      buffer_id: buffer_id,
      diff: %{action: "away", nick: "akash", status: "away"}
    }

    assert buffer_id == "channel:#{membership.id}"
  end

  test "pushes role presence diffs over the user channel" do
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(user, %{
        "name" => "local",
        "host" => "127.0.0.1",
        "port" => 6667,
        "use_tls" => false,
        "nickname" => "mira"
      })

    {:ok, membership} = Chat.join_channel(user, connection, "#elixir")
    join_user_channel(user)

    Chat.broadcast_presence_diff(connection, "#elixir", %{
      action: "role",
      nick: "akash",
      role: "op"
    })

    assert_push "presence:diff", %{
      type: "presence:diff",
      version: 1,
      event_id: "presence_diff:channel:" <> _,
      buffer_id: buffer_id,
      diff: %{action: "role", nick: "akash", role: "op"}
    }

    assert buffer_id == "channel:#{membership.id}"
  end

  test "pushes joined buffers over the user channel" do
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(user, %{
        "name" => "local",
        "host" => "127.0.0.1",
        "port" => 6667,
        "use_tls" => false,
        "nickname" => "mira"
      })

    join_user_channel(user)

    {:ok, membership} = Chat.join_channel(user, connection, "#elixir")

    assert_push "buffer:joined", %{
      type: "buffer:joined",
      version: 1,
      event_id: "buffer_joined:channel:" <> _,
      buffer: %{
        buffer_id: buffer_id,
        buffer_type: "channel",
        title: "#elixir",
        server_connection_id: connection_id,
        channel_membership_id: membership_id
      },
      connection: %{id: connection_id}
    }

    assert buffer_id == "channel:#{membership.id}"
    assert connection_id == connection.id
    assert membership_id == membership.id
  end

  test "does not push server status broadcasts to another user's channel" do
    user = AccountsFixtures.user_fixture()
    other_user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(other_user, %{
        "name" => "local",
        "host" => "127.0.0.1",
        "port" => 6667,
        "use_tls" => false,
        "nickname" => "other"
      })

    join_user_channel(user)

    {:ok, _connection} = ConnectionLifecycle.update_status(connection, "connected")

    refute_push "server:status", %{server_connection_id: _connection_id}, 100
  end

  test "leaves a channel buffer through the IRC session" do
    server = start_supervised!({IrcTestServer, self()})
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(user, %{
        "name" => "local",
        "host" => "127.0.0.1",
        "port" => IrcTestServer.port(server),
        "use_tls" => false,
        "nickname" => "mira"
      })

    {:ok, membership} = Chat.join_channel(user, connection, "#elixir")
    {:ok, _pid} = SessionSupervisor.start_session(connection)

    assert_receive {:irc_server_line, "NICK mira"}, 1_000
    assert_receive {:irc_server_line, "USER mira 0 * mira"}, 1_000
    assert_receive {:irc_server_line, "JOIN #elixir"}, 1_000

    socket = join_user_channel(user)
    ref = push(socket, "channel:leave", %{"buffer_id" => "channel:#{membership.id}"})

    assert_reply ref, :ok, %{
      status: "sent",
      buffer_id: "channel:" <> _,
      channel_membership_id: membership_id
    }

    assert membership_id == membership.id
    assert_receive {:irc_server_line, "PART #elixir leaving"}, 1_000

    assert_push "buffer:left", %{
      type: "buffer:left",
      buffer_id: buffer_id,
      channel_membership_id: ^membership_id
    }

    assert buffer_id == "channel:#{membership.id}"
    left_membership = Chat.get_membership!(user, membership.id)
    assert left_membership.status == "left"
    assert left_membership.auto_join == false
    assert left_membership.left_at
    assert :ok = Session.quit(connection)
  end

  test "opens a server channel directory directly and through /list" do
    server = start_supervised!({IrcTestServer, self()})
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(user, %{
        "name" => "local",
        "host" => "127.0.0.1",
        "port" => IrcTestServer.port(server),
        "use_tls" => false,
        "nickname" => "mira"
      })

    Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{user.id}")
    socket = join_user_channel(user)
    {:ok, _pid} = SessionSupervisor.start_session(connection)
    assert_receive {:irc_server_line, "NICK mira"}, 1_000
    assert_receive {:irc_server_line, "USER mira 0 * mira"}, 1_000
    assert_push "buffer:system", %{body: "Connected to 127.0.0.1."}
    direct_ref = push(socket, "server:list", %{"server_connection_id" => connection.id})

    assert_reply direct_ref, :ok, %{
      reply: "ok",
      directory: %{
        server_connection_id: server_connection_id,
        server_name: "local",
        channels: [
          %{channel: "#elixir", users: 42},
          %{channel: "#quiet", users: 4},
          %{channel: "&local", users: 3}
        ]
      }
    }

    assert server_connection_id == connection.id
    assert_receive {:irc_server_line, "LIST"}, 1_000

    command_ref =
      push(socket, "command:run", %{
        "input" => "/list",
        "buffer_id" => "server:#{connection.id}"
      })

    assert_reply command_ref, :ok, %{
      command: %{name: "list", args: []},
      directory: %{
        server_connection_id: ^server_connection_id,
        channels: [_first, _second, _third]
      }
    }

    assert_receive {:irc_server_line, "LIST"}, 1_000
    assert :ok = Session.quit(connection)
  end

  test "runs a parsed quote query and persists correlated command results" do
    server = start_supervised!({IrcTestServer, self()})
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(user, %{
        "name" => "local",
        "host" => "127.0.0.1",
        "port" => IrcTestServer.port(server),
        "use_tls" => false,
        "nickname" => "mira"
      })

    socket = join_user_channel(user)
    {:ok, _pid} = SessionSupervisor.start_session(connection)
    assert_receive {:irc_server_line, "NICK mira"}, 1_000
    assert_receive {:irc_server_line, "USER mira 0 * mira"}, 1_000
    assert_push "buffer:system", %{body: "Connected to 127.0.0.1."}

    ref =
      push(socket, "command:run", %{
        "command_id" => "whois-mira-1",
        "input" => "/quote WHOIS mira",
        "buffer_id" => "server:#{connection.id}"
      })

    assert_reply ref, :ok, %{
      command_id: "whois-mira-1",
      status: "sent",
      display: "WHOIS mira"
    }

    assert_receive {:irc_server_line, "WHOIS mira"}, 1_000

    assert_push "buffer:system", %{
      metadata: %{
        "command_id" => "whois-mira-1",
        "command_status" => "result",
        "irc_event" => "whois_user"
      }
    }

    assert_push "buffer:system", %{
      metadata: %{
        "command_id" => "whois-mira-1",
        "command_status" => "completed"
      }
    }

    _ = :sys.get_state(Session.via(connection))

    messages = MessageHistory.list_buffer_messages(user, "server:#{connection.id}")

    assert Enum.any?(messages, fn message ->
             message.metadata["command_id"] == "whois-mira-1" and
               message.metadata["command_status"] == "completed"
           end)

    assert :ok = Session.quit(connection)
  end

  test "rejects protocol-owned quote commands before IRC transmission" do
    server = start_supervised!({IrcTestServer, self()})
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(user, %{
        "name" => "local",
        "host" => "127.0.0.1",
        "port" => IrcTestServer.port(server),
        "use_tls" => false,
        "nickname" => "mira"
      })

    {:ok, _pid} = SessionSupervisor.start_session(connection)
    assert_receive {:irc_server_line, "NICK mira"}, 1_000
    assert_receive {:irc_server_line, "USER mira 0 * mira"}, 1_000
    socket = join_user_channel(user)

    ref =
      push(socket, "command:run", %{
        "command_id" => "denied-ping-1",
        "input" => "/quote PING test-token",
        "buffer_id" => "server:#{connection.id}"
      })

    assert_reply ref, :error, %{
      command_id: "denied-ping-1",
      reason: "protocol_owned",
      error: %{code: "protocol_owned"}
    }

    refute_receive {:irc_server_line, "PING test-token"}, 100
    assert :ok = Session.quit(connection)
  end

  test "disconnects and reconnects an owned server over the user channel" do
    server = start_supervised!({IrcTestServer, self()})
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(user, %{
        "name" => "local",
        "host" => "127.0.0.1",
        "port" => IrcTestServer.port(server),
        "use_tls" => false,
        "nickname" => "mira"
      })

    socket = join_user_channel(user)
    reconnect_ref = push(socket, "server:reconnect", %{"server_connection_id" => connection.id})

    assert_reply reconnect_ref, :ok, %{
      type: "server:status",
      server_connection_id: server_connection_id,
      status: "connecting"
    }

    assert server_connection_id == connection.id
    assert_receive {:irc_server_line, "NICK mira"}, 1_000
    assert_receive {:irc_server_line, "USER mira 0 * mira"}, 1_000

    disconnect_ref = push(socket, "server:disconnect", %{"server_connection_id" => connection.id})

    assert_reply disconnect_ref, :ok, %{
      type: "server:status",
      server_connection_id: ^server_connection_id,
      status: "disconnected"
    }

    assert Session.status(connection) == "disconnected"
  end

  defp join_user_channel(user) do
    assert {:ok, _reply, socket} =
             authenticated_socket(user)
             |> subscribe_and_join(UserChannel, "user:#{user.id}")

    socket
  end

  defp authenticated_socket(user) do
    token = Accounts.generate_user_session_token(user)

    UserSocket
    |> socket(UserSocket.id_for_session_token(token), %{
      current_user: user,
      session_token: token,
      session_token_inserted_at: DateTime.utc_now(:second),
      session_socket_id: UserSocket.id_for_session_token(token)
    })
  end
end
