defmodule IrcpipeWeb.InternalEvents.RealtimeHandlerTest do
  use ExUnit.Case, async: true

  alias Ircpipe.InternalEvent
  alias IrcpipeWeb.InternalEvents.RealtimeHandler

  @occurred_at ~U[2026-08-28 10:11:12Z]

  setup do
    user_id = System.unique_integer([:positive])
    Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{user_id}")
    %{user_id: user_id}
  end

  test "freezes non-message internal facts into their browser payloads", %{user_id: user_id} do
    fixtures = [
      {
        "buffer_left",
        %{connection_id: 7, membership_id: 8, channel: "#elixir"},
        :buffer_left,
        %{
          type: "buffer:left",
          version: 1,
          event_id: "browser:buffer_left",
          occurred_at: @occurred_at,
          buffer_id: "channel:8",
          server_connection_id: 7,
          channel_membership_id: 8,
          channel: "#elixir"
        }
      },
      {
        "buffer_read",
        %{connection_id: 7, membership_id: nil, unread_count: 0, mention_count: 0},
        :buffer_read,
        %{
          type: "buffer:read",
          version: 1,
          event_id: "browser:buffer_read",
          occurred_at: @occurred_at,
          buffer_id: "server:7",
          server_connection_id: 7,
          channel_membership_id: nil,
          unread_count: 0,
          mention_count: 0
        }
      },
      {
        "buffer_joined",
        %{connection: connection(), membership: membership(), status: "connected"},
        :buffer_joined,
        %{
          type: "buffer:joined",
          version: 1,
          event_id: "browser:buffer_joined",
          occurred_at: @occurred_at,
          buffer: %{
            buffer_id: "channel:8",
            buffer_type: "channel",
            server_connection_id: 7,
            channel_membership_id: 8,
            title: "#elixir",
            subtitle: "on irc.example.test",
            status: "connected",
            membership_status: "joined",
            unread_count: 2,
            mention_count: 1,
            mention_notifications_enabled: true,
            notification_preference_revision: 4
          },
          connection: %{
            id: 7,
            name: "libera",
            host: "irc.example.test",
            port: 6697,
            use_tls: true,
            nickname: "mira",
            status: "connected",
            mention_notifications_enabled: true,
            notification_preference_revision: 3
          }
        }
      },
      {
        "connection_status_changed",
        %{connection: connection(), status: "connected"},
        :server_status,
        %{
          type: "server:status",
          version: 1,
          event_id: "browser:connection_status_changed",
          occurred_at: @occurred_at,
          server_connection_id: 7,
          nickname: "mira",
          status: "connected"
        }
      },
      {
        "direct_message_thread_changed",
        %{thread: thread(), connection: connection()},
        :direct_message_thread,
        %{
          type: "direct_message:thread",
          version: 1,
          event_id: "browser:direct_message_thread_changed",
          occurred_at: @occurred_at,
          revision: 2,
          buffer: %{
            buffer_id: "direct:10",
            buffer_type: "direct_message",
            server_connection_id: 7,
            direct_message_thread_id: 10,
            direct_message_revision: 2,
            title: "akash",
            subtitle: "on irc.example.test",
            peer_nick: "akash",
            account: "akash-account",
            hostmask: "akash!user@example.test",
            blocked: false,
            closed_at: nil,
            unread_count: 1,
            mention_count: 0
          },
          connection: %{
            id: 7,
            name: "libera",
            host: "irc.example.test",
            port: 6697,
            use_tls: true,
            nickname: "mira",
            status: "connected",
            mention_notifications_enabled: true,
            notification_preference_revision: 3
          }
        }
      },
      {
        "direct_message_thread_closed",
        %{thread: thread()},
        :direct_message_closed,
        %{
          type: "direct_message:closed",
          version: 1,
          event_id: "browser:direct_message_thread_closed",
          occurred_at: @occurred_at,
          buffer_id: "direct:10",
          server_connection_id: 7,
          direct_message_thread_id: 10,
          revision: 2
        }
      },
      {
        "presence_synchronized",
        %{connection_id: 7, membership_id: 8, users: [presence_user()]},
        :presence_sync,
        %{
          type: "presence:sync",
          version: 1,
          event_id: "browser:presence_synchronized",
          occurred_at: @occurred_at,
          buffer_id: "channel:8",
          server_connection_id: 7,
          channel_membership_id: 8,
          users: [
            %{
              nick: "akash",
              nick_key: "akash",
              role: "op",
              status: "online",
              hostmask: "akash!user@example.test",
              last_observed_at: @occurred_at
            }
          ]
        }
      },
      {
        "presence_changed",
        %{
          connection_id: 7,
          membership_id: 8,
          diff: %{action: "part", nick: "akash", nick_key: "akash"}
        },
        :presence_diff,
        %{
          type: "presence:diff",
          version: 1,
          event_id: "browser:presence_changed",
          occurred_at: @occurred_at,
          buffer_id: "channel:8",
          server_connection_id: 7,
          channel_membership_id: 8,
          diff: %{action: "part", nick: "akash", nick_key: "akash"}
        }
      }
    ]

    Enum.each(fixtures, fn {type, data, pubsub_name, expected} ->
      event = internal_event(type, user_id, data)
      assert :ok = RealtimeHandler.dispatch(event)
      assert_receive {^pubsub_name, ^expected}
    end)
  end

  test "freezes every committed-message destination and browser message type", %{
    user_id: user_id
  } do
    fixtures = [
      {
        "channel",
        %{connection: connection(), membership: membership()},
        message(),
        :buffer_message,
        %{buffer_id: "channel:8", channel: "#elixir"}
      },
      {
        "channel_attention",
        %{connection: connection(), membership: membership()},
        %{message() | mentioned: true},
        :buffer_message,
        %{
          buffer_id: "channel:8",
          channel: "#elixir",
          unread_count: 2,
          mention_count: 1
        }
      },
      {
        "server",
        %{connection: connection()},
        %{message() | channel_membership_id: nil, kind: "error"},
        :buffer_error,
        %{buffer_id: "server:7", mentioned: false}
      },
      {
        "server",
        %{connection: connection()},
        %{message() | channel_membership_id: nil, kind: "system"},
        :buffer_system,
        %{buffer_id: "server:7", mentioned: false}
      },
      {
        "direct",
        %{thread: thread()},
        %{message() | channel_membership_id: nil, direct_message_thread_id: 10},
        :buffer_message,
        %{buffer_id: "direct:10", peer_nick: "akash", blocked: false}
      }
    ]

    Enum.with_index(fixtures, 1)
    |> Enum.each(fn {{delivery, destination, source_message, pubsub_name, extra}, index} ->
      type = "message_committed_#{index}"

      event =
        internal_event(
          "message_committed",
          user_id,
          destination
          |> Map.put(:delivery, delivery)
          |> Map.put(:message, source_message),
          event_id: "browser:#{type}"
        )

      expected =
        Map.merge(
          %{
            type: browser_message_type(source_message.kind),
            version: 1,
            event_id: "browser:#{type}",
            id: 9,
            buffer_id: nil,
            channel_membership_id: source_message.channel_membership_id,
            direct_message_thread_id: source_message.direct_message_thread_id,
            server_connection_id: 7,
            nick: "akash",
            hostmask: "akash!user@example.test",
            sender_role: "op",
            service: nil,
            metadata: %{},
            body: "hello",
            kind: source_message.kind,
            mentioned: source_message.mentioned,
            occurred_at: @occurred_at
          },
          extra
        )

      assert :ok = RealtimeHandler.dispatch(event)
      assert_receive {^pubsub_name, ^expected}
    end)
  end

  defp internal_event(type, user_id, data, opts \\ []) do
    InternalEvent.new!(type, user_id, data,
      event_id: Keyword.get(opts, :event_id, "browser:#{type}"),
      occurred_at: @occurred_at
    )
  end

  defp connection do
    %{
      id: 7,
      user_id: 42,
      name: "libera",
      host: "irc.example.test",
      port: 6697,
      use_tls: true,
      nickname: "mira",
      status: "connected",
      desired_state: "connected",
      mention_notifications_enabled: true,
      notification_preference_revision: 3
    }
  end

  defp membership do
    %{
      id: 8,
      user_id: 42,
      server_connection_id: 7,
      channel: "#elixir",
      status: "joined",
      auto_join: true,
      unread_count: 2,
      mention_count: 1,
      mention_notifications_enabled: true,
      notification_preference_revision: 4,
      joined_at: "2026-08-28T10:11:12Z",
      left_at: nil
    }
  end

  defp message do
    %{
      id: 9,
      user_id: 42,
      server_connection_id: 7,
      channel_membership_id: 8,
      direct_message_thread_id: nil,
      nick: "akash",
      hostmask: "akash!user@example.test",
      sender_role: "op",
      service: nil,
      metadata: %{},
      body: "hello",
      kind: "message",
      mentioned: false,
      occurred_at: "2026-08-28T10:11:12Z"
    }
  end

  defp thread do
    %{
      id: 10,
      user_id: 42,
      server_connection_id: 7,
      peer_nick: "akash",
      account: "akash-account",
      hostmask: "akash!user@example.test",
      blocked_at: nil,
      closed_at: nil,
      unread_count: 1,
      mutation_revision: 2
    }
  end

  defp presence_user do
    %{
      nick: "akash",
      nick_key: "akash",
      role: "op",
      status: "online",
      hostmask: "akash!user@example.test",
      last_observed_at: "2026-08-28T10:11:12Z"
    }
  end

  defp browser_message_type("error"), do: "buffer:error"
  defp browser_message_type("system"), do: "buffer:system"
  defp browser_message_type(_kind), do: "buffer:message"
end
