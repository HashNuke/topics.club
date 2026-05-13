defmodule IrcpipeWeb.UserChannelTest do
  use IrcpipeWeb.ChannelCase

  alias Ircpipe.AccountsFixtures
  alias Ircpipe.Chat
  alias Ircpipe.Irc.Session
  alias Ircpipe.Irc.SessionSupervisor
  alias Ircpipe.IrcTestServer
  alias IrcpipeWeb.UserChannel
  alias IrcpipeWeb.UserSocket

  test "joins with server time and missed event cursor metadata" do
    user = AccountsFixtures.user_fixture()

    assert {:ok, %{server_time: server_time, missed_event_cursor: nil}, _socket} =
             UserSocket
             |> socket("user_socket:#{user.id}", %{current_user: user})
             |> subscribe_and_join(UserChannel, "user:#{user.id}")

    assert {:ok, _datetime, 0} = DateTime.from_iso8601(server_time)
  end

  test "suggests slash commands over the user channel" do
    user = AccountsFixtures.user_fixture()

    socket = join_user_channel(user)

    ref = push(socket, "command:suggest", %{"input" => "/jo"})

    assert_reply ref, :ok, %{commands: [%{name: "/join"}]}
  end

  test "parses supported slash commands over the user channel" do
    user = AccountsFixtures.user_fixture()

    socket = join_user_channel(user)

    ref = push(socket, "command:parse", %{"input" => "/msg NickServ help"})

    assert_reply ref, :ok, %{command: %{name: "msg", args: ["NickServ", "help"]}}
  end

  test "runs supported slash commands over the user channel" do
    user = AccountsFixtures.user_fixture()
    socket = join_user_channel(user)

    ref = push(socket, "command:run", %{"input" => "/join #elixir"})

    assert_reply ref, :ok, %{command: %{name: "join", args: ["#elixir"]}}
  end

  test "rejects unknown slash commands over the user channel" do
    user = AccountsFixtures.user_fixture()
    socket = join_user_channel(user)

    ref = push(socket, "command:parse", %{"input" => "/wat"})

    assert_reply ref, :error, %{reason: "unknown_command", command: "wat"}
  end

  test "sends channel messages through the IRC session and replies with canonical message" do
    server = start_supervised!({IrcTestServer, self()})
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Chat.create_connection(user, %{
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
    assert [%{body: "hello from channel", nick: "mira"}] = Chat.list_messages(user, membership.id)

    assert :ok = Session.quit(connection)
  end

  test "rejects channel messages for buffers the user does not own" do
    user = AccountsFixtures.user_fixture()
    other_user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Chat.create_connection(other_user, %{
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

  test "marks a channel buffer read over the user channel" do
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Chat.create_connection(user, %{
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

    reloaded = Chat.get_membership!(user, membership.id)
    assert reloaded.unread_count == 0
    assert reloaded.mention_count == 0
  end

  test "pushes server status broadcasts over the user channel" do
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Chat.create_connection(user, %{
        "name" => "local",
        "host" => "127.0.0.1",
        "port" => 6667,
        "use_tls" => false,
        "nickname" => "mira"
      })

    join_user_channel(user)

    {:ok, _connection} = Chat.update_connection_status(connection, "connected")

    assert_push "server:status", %{
      type: "server:status",
      server_connection_id: connection_id,
      status: "connected"
    }

    assert connection_id == connection.id
  end

  test "pushes server buffer messages over the user channel" do
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Chat.create_connection(user, %{
        "name" => "local",
        "host" => "127.0.0.1",
        "port" => 6667,
        "use_tls" => false,
        "nickname" => "mira"
      })

    join_user_channel(user)

    Chat.record_server_message(connection, "MOTD starts here", "notice")

    assert_push "buffer:message", %{
      type: "buffer:message",
      buffer_id: buffer_id,
      server_connection_id: connection_id,
      channel_membership_id: nil,
      body: "MOTD starts here",
      kind: "notice"
    }

    assert buffer_id == "server:#{connection.id}"
    assert connection_id == connection.id
  end

  test "pushes mention notifications over the user channel" do
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Chat.create_connection(user, %{
        "name" => "local",
        "host" => "127.0.0.1",
        "port" => 6667,
        "use_tls" => false,
        "nickname" => "mira"
      })

    {:ok, _membership} = Chat.join_channel(user, connection, "#elixir")
    join_user_channel(user)

    Chat.record_inbound_message(connection, "#elixir", "akash", "hello mira")

    assert_push "notification:mention", %{body: "hello mira", mentioned: true}
  end

  test "pushes presence sync over the user channel" do
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Chat.create_connection(user, %{
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
      Chat.create_connection(user, %{
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
      buffer_id: buffer_id,
      diff: %{action: "join", user: %{nick: "akash", role: "user", status: "online"}}
    }

    assert buffer_id == "channel:#{membership.id}"
  end

  test "does not push server status broadcasts to another user's channel" do
    user = AccountsFixtures.user_fixture()
    other_user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Chat.create_connection(other_user, %{
        "name" => "local",
        "host" => "127.0.0.1",
        "port" => 6667,
        "use_tls" => false,
        "nickname" => "other"
      })

    join_user_channel(user)

    {:ok, _connection} = Chat.update_connection_status(connection, "connected")

    refute_push "server:status", %{server_connection_id: _connection_id}, 100
  end

  test "leaves a channel buffer through the IRC session" do
    server = start_supervised!({IrcTestServer, self()})
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Chat.create_connection(user, %{
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
    ref = push(socket, "channel:leave", %{"buffer_id" => "channel:#{membership.id}"})

    assert_reply ref, :ok, %{
      type: "buffer:left",
      buffer_id: "channel:" <> _,
      channel_membership_id: membership_id
    }

    assert membership_id == membership.id

    assert_push "buffer:left", %{
      type: "buffer:left",
      buffer_id: buffer_id,
      channel_membership_id: ^membership_id
    }

    assert buffer_id == "channel:#{membership.id}"
    assert_receive {:irc_server_line, "PART #elixir leaving"}, 1_000

    assert_raise Ecto.NoResultsError, fn -> Chat.get_membership!(user, membership.id) end
    assert :ok = Session.quit(connection)
  end

  test "disconnects and reconnects an owned server over the user channel" do
    server = start_supervised!({IrcTestServer, self()})
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Chat.create_connection(user, %{
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

    reloaded = Chat.get_connection!(user, connection.id)
    assert reloaded.status == "disconnected"
  end

  defp join_user_channel(user) do
    assert {:ok, _reply, socket} =
             UserSocket
             |> socket("user_socket:#{user.id}", %{current_user: user})
             |> subscribe_and_join(UserChannel, "user:#{user.id}")

    socket
  end
end
