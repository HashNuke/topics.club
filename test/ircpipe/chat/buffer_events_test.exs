defmodule Ircpipe.Chat.BufferEventsTest do
  use Ircpipe.DataCase, async: true

  alias Ircpipe.AccountsFixtures
  alias Ircpipe.Chat
  alias Ircpipe.Chat.BufferEvents
  alias Ircpipe.Chat.Connections
  alias Ircpipe.Chat.{DirectMessageThread, Message}

  test "broadcasts buffer-left and buffer-read events only to the owning user" do
    user = AccountsFixtures.user_fixture()
    other_user = AccountsFixtures.user_fixture()
    Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{user.id}")

    left_payload = %{
      user_id: user.id,
      buffer_id: "channel:41",
      server_connection_id: 17,
      channel_membership_id: 41
    }

    BufferEvents.left(left_payload)

    assert_receive {:buffer_left, left_event}
    assert left_event.type == "buffer:left"
    assert left_event.buffer_id == "channel:41"
    refute Map.has_key?(left_event, :user_id)

    BufferEvents.read(%{left_payload | user_id: other_user.id})
    refute_receive {:buffer_read, _event}

    BufferEvents.read(left_payload)

    assert_receive {:buffer_read, read_event}
    assert read_event.type == "buffer:read"
    assert read_event.unread_count == 0
    assert read_event.mention_count == 0
    refute Map.has_key?(read_event, :user_id)
  end

  test "broadcasts joined membership state to the connection owner" do
    user = AccountsFixtures.user_fixture()

    assert {:ok, connection} =
             Connections.create(user, %{
               "name" => "joined events",
               "host" => "irc.joined.test",
               "nickname" => "mira"
             })

    assert {:ok, membership} = Chat.join_channel(user, connection, "#elixir")
    Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{user.id}")

    BufferEvents.joined(connection, membership, "connected")

    assert_receive {:buffer_joined, event}
    assert event.type == "buffer:joined"
    assert event.buffer.server_connection_id == connection.id
    assert event.buffer.channel_membership_id == membership.id
    assert event.connection.status == "connected"
  end

  test "broadcasts channel, server, and direct messages with their buffer event types" do
    user = AccountsFixtures.user_fixture()

    assert {:ok, connection} =
             Connections.create(user, %{
               "name" => "message events",
               "host" => "irc.message-events.test",
               "nickname" => "mira"
             })

    assert {:ok, membership} = Chat.join_channel(user, connection, "#elixir")
    Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{user.id}")

    channel_message = message_fixture(user.id, connection.id, membership.id, "message")
    assert :ok = BufferEvents.message(channel_message, membership, connection)

    assert_receive {:buffer_message, %{id: 101, buffer_id: channel_buffer_id}}
    assert channel_buffer_id == "channel:#{membership.id}"
    refute_received {:irc_message, _event}

    server_message = message_fixture(user.id, connection.id, nil, "system")
    assert :ok = BufferEvents.server_message(server_message, connection)
    assert_receive {:buffer_system, %{buffer_id: server_buffer_id, mentioned: false}}
    assert server_buffer_id == "server:#{connection.id}"

    thread = %DirectMessageThread{
      id: 303,
      user_id: user.id,
      server_connection_id: connection.id,
      peer_nick: "akash",
      peer_key: "akash",
      mutation_revision: 1
    }

    direct_message = message_fixture(user.id, connection.id, nil, "message")

    assert :ok = BufferEvents.direct_message(direct_message, thread)

    assert_receive {:buffer_message,
                    %{buffer_id: "direct:303", peer_nick: "akash", blocked: false}}
  end

  test "broadcasts direct-message thread lifecycle events" do
    user = AccountsFixtures.user_fixture()

    assert {:ok, connection} =
             Connections.create(user, %{
               "name" => "thread events",
               "host" => "irc.thread-events.test",
               "nickname" => "mira"
             })

    thread = %DirectMessageThread{
      id: 404,
      user_id: user.id,
      server_connection_id: connection.id,
      peer_nick: "akash",
      peer_key: "akash",
      mutation_revision: 2,
      closed_at: DateTime.utc_now(:second)
    }

    Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{user.id}")

    assert :ok = BufferEvents.direct_message_thread(thread)
    assert_receive {:direct_message_thread, %{buffer: %{direct_message_thread_id: 404}}}

    assert :ok = BufferEvents.direct_message_closed(thread)

    assert_receive {:direct_message_closed, %{direct_message_thread_id: 404, revision: 2}}
  end

  test "refuses to publish an event from inside a rollback-capable transaction" do
    user = AccountsFixtures.user_fixture()

    assert {:ok, connection} =
             Connections.create(user, %{
               "name" => "rollback events",
               "host" => "irc.rollback-events.test",
               "nickname" => "mira"
             })

    assert {:ok, membership} = Chat.join_channel(user, connection, "#elixir")
    Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{user.id}")
    message = message_fixture(user.id, connection.id, membership.id, "message")

    assert_raise ArgumentError, ~r/must be published after the transaction commits/, fn ->
      Repo.transaction(fn ->
        BufferEvents.message(message, membership, connection)
        Repo.rollback(:forced_rollback)
      end)
    end

    refute_receive {:buffer_message, _event}
  end

  defp message_fixture(user_id, connection_id, membership_id, kind) do
    %Message{
      id: 101,
      user_id: user_id,
      server_connection_id: connection_id,
      channel_membership_id: membership_id,
      kind: kind,
      nick: "akash",
      body: "hello",
      mentioned: true,
      metadata: %{},
      occurred_at: DateTime.utc_now(:second)
    }
  end
end
