defmodule Ircpipe.Chat.BufferEventsTest do
  use Ircpipe.DataCase, async: true

  alias Ircpipe.AccountsFixtures
  alias Ircpipe.Chat
  alias Ircpipe.Chat.BufferEvents
  alias Ircpipe.Chat.Connections

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
end
