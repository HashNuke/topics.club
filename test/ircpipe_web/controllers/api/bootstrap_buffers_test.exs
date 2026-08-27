defmodule IrcpipeWeb.Api.BootstrapBuffersTest do
  use ExUnit.Case, async: true

  alias Ircpipe.Chat.{ChannelMembership, DirectMessageThread, ServerConnection}
  alias IrcpipeWeb.Api.BootstrapBuffers

  test "builds server, direct-message, and visible channel buffers" do
    closed_at = ~U[2026-08-27 00:00:00Z]

    connection = %ServerConnection{
      id: 10,
      user_id: 20,
      name: "Libera",
      host: "irc.libera.chat",
      unread_count: 3,
      mention_count: 2,
      mention_notifications_enabled: false,
      notification_preference_revision: 4,
      direct_message_threads: [
        %DirectMessageThread{
          id: 30,
          peer_nick: "mira",
          mutation_revision: 5,
          unread_count: 6,
          account: "mira-account",
          hostmask: "mira@example.test",
          blocked_at: closed_at,
          closed_at: closed_at
        }
      ],
      channel_memberships: [
        %ChannelMembership{
          id: 40,
          channel: "#elixir",
          status: "joined",
          unread_count: 7,
          mention_count: 1,
          mention_notifications_enabled: true,
          notification_preference_revision: 8
        },
        %ChannelMembership{id: 41, channel: "#pending", status: "pending"},
        %ChannelMembership{id: 42, channel: "#left", status: "left"}
      ]
    }

    assert [server, direct_message, joined, pending] =
             BootstrapBuffers.for_connection(connection)

    assert server == %{
             buffer_id: "server:10",
             buffer_type: "server",
             server_connection_id: 10,
             channel_membership_id: nil,
             title: "irc.libera.chat",
             subtitle: "Libera",
             status: "disconnected",
             unread_count: 3,
             mention_count: 2,
             mention_notifications_enabled: false,
             notification_preference_revision: 4
           }

    assert direct_message.buffer_id == "direct:30"
    assert direct_message.direct_message_revision == 5
    assert direct_message.blocked
    assert direct_message.closed_at == closed_at

    assert joined.buffer_id == "channel:40"
    assert joined.membership_status == "joined"
    assert joined.notification_preference_revision == 8
    assert pending.buffer_id == "channel:41"
  end

  test "chooses a joined channel, then any channel, then the first buffer" do
    server = %{buffer_id: "server:1", buffer_type: "server"}
    pending = %{buffer_id: "channel:2", buffer_type: "channel", membership_status: "pending"}
    joined = %{buffer_id: "channel:3", buffer_type: "channel", membership_status: "joined"}

    assert BootstrapBuffers.active_id([server, pending, joined]) == "channel:3"
    assert BootstrapBuffers.active_id([server, pending]) == "channel:2"
    assert BootstrapBuffers.active_id([server]) == "server:1"
    assert BootstrapBuffers.active_id([]) == nil
  end
end
