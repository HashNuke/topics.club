import React from "react"
import {describe, expect, test, vi} from "vitest"
import {act, fireEvent, render, screen, waitFor, within} from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import TopicsClubApp, {appendMention, appendTimelineMessage, trimMessagesToLimit, visibleTimelineMessages} from "./topics_club_app.tsx"

const topicFixtures = [
  {id: 101, name: "#elixir", description: "Phoenix, OTP, releases, and production Elixir help.", server_host: "127.0.0.1", server_port: 6669, use_tls: false, channel: "#elixir"},
  {id: 102, name: "#phoenix", description: "LiveView patterns, web UI questions, and framework support.", server_host: "127.0.0.1", server_port: 6669, use_tls: false, channel: "#phoenix"},
  {id: 103, name: "#linux", description: "Daily Linux discussion and troubleshooting.", server_host: "127.0.0.1", server_port: 6669, use_tls: false, channel: "#linux"},
]

const featuredChannelFixtures = [
  {id: 201, name: "#ruby", topic: "Ruby, Rails, gems, and the wider ecosystem.", user_count: 420, network_id: 1, network_name: "Libera.Chat", server_host: "irc.libera.chat", server_port: 6697, use_tls: true},
  {id: 202, name: "#python", topic: "Python help, packaging, and community projects.", user_count: 1200, network_id: 1, network_name: "Libera.Chat", server_host: "irc.libera.chat", server_port: 6697, use_tls: true},
  {id: 203, name: "#linux", topic: "Linux help, news, and daily driver talk.", user_count: 1800, network_id: 1, network_name: "Libera.Chat", server_host: "irc.libera.chat", server_port: 6697, use_tls: true},
]

const systemMessageKinds = new Set([
  "system",
  "command",
  "join",
  "part",
  "quit",
  "nick",
  "topic",
  "mode",
  "kick",
])

function canonicalMessage(message = {}) {
  const id = message.id || 1
  const bufferId = message.buffer_id || "channel:7"
  const kind = message.kind || "message"
  const channelMembershipId = bufferId.startsWith("channel:")
    ? Number(bufferId.slice("channel:".length))
    : null
  const directMessageThreadId = bufferId.startsWith("direct:")
    ? Number(bufferId.slice("direct:".length))
    : null

  return {
    type: kind === "error"
      ? "buffer:error"
      : systemMessageKinds.has(kind)
        ? "buffer:system"
        : "buffer:message",
    version: 1,
    id,
    event_id: `message:${id}`,
    buffer_id: bufferId,
    server_connection_id: bufferId.startsWith("server:")
      ? Number(bufferId.slice("server:".length))
      : bufferId.startsWith("channel:")
        ? 42
        : 1,
    channel_membership_id: channelMembershipId,
    direct_message_thread_id: directMessageThreadId,
    occurred_at: "2026-05-13T10:00:00Z",
    nick: systemMessageKinds.has(kind) ? null : "mira",
    hostmask: null,
    sender_role: null,
    service: null,
    body: "message",
    kind,
    mentioned: false,
    metadata: {},
    ...message,
  }
}

function canonicalServerStatus(status, overrides = {}) {
  return {
    type: "server:status",
    version: 1,
    event_id: "server_status:42:1",
    occurred_at: "2026-05-13T10:00:00Z",
    server_connection_id: 42,
    status,
    nickname: "mira",
    ...overrides,
  }
}

function canonicalBufferLeft(bufferId, overrides = {}) {
  const channelMembershipId = bufferId.startsWith("channel:")
    ? Number(bufferId.slice("channel:".length))
    : null

  return {
    type: "buffer:left",
    version: 1,
    event_id: `buffer_left:${bufferId}:1`,
    occurred_at: "2026-05-13T10:00:00Z",
    buffer_id: bufferId,
    server_connection_id: 42,
    channel_membership_id: channelMembershipId,
    ...overrides,
  }
}

function canonicalBufferRead(bufferId, overrides = {}) {
  const channelMembershipId = bufferId.startsWith("channel:")
    ? Number(bufferId.slice("channel:".length))
    : null

  return {
    type: "buffer:read",
    version: 1,
    event_id: `buffer_read:${bufferId}:1`,
    occurred_at: "2026-05-13T10:00:00Z",
    buffer_id: bufferId,
    server_connection_id: 42,
    channel_membership_id: channelMembershipId,
    unread_count: 0,
    mention_count: 0,
    ...overrides,
  }
}

function canonicalBufferJoined(payload) {
  return {
    type: "buffer:joined",
    version: 1,
    event_id: `buffer_joined:${payload.buffer.buffer_id}:1`,
    occurred_at: "2026-05-13T10:00:00Z",
    ...payload,
  }
}

function directThreadPayload(payload) {
  const threadId = payload.buffer.direct_message_thread_id
  const title = payload.buffer.title

  return {
    type: "direct_message:thread",
    version: 1,
    event_id: `direct_message_thread:${threadId}:1`,
    occurred_at: "2026-08-26T00:00:00Z",
    ...payload,
    buffer: {
      subtitle: `on ${payload.connection.host}`,
      peer_nick: title,
      account: null,
      hostmask: null,
      closed_at: null,
      unread_count: 0,
      mention_count: 0,
      ...payload.buffer,
    },
  }
}

function directBufferRecord(id, title, overrides = {}) {
  return {
    buffer_id: `direct:${id}`,
    buffer_type: "direct_message",
    server_connection_id: 1,
    direct_message_thread_id: id,
    direct_message_revision: 1,
    title,
    subtitle: "on irc.old.test",
    peer_nick: title,
    account: null,
    hostmask: null,
    blocked: false,
    closed_at: null,
    unread_count: 0,
    mention_count: 0,
    ...overrides,
  }
}

function directClosedPayload(threadId, revision, overrides = {}) {
  return {
    type: "direct_message:closed",
    version: 1,
    event_id: `direct_message_closed:${threadId}:${Math.max(1, revision)}`,
    occurred_at: "2026-08-26T00:00:00Z",
    buffer_id: `direct:${threadId}`,
    server_connection_id: 1,
    direct_message_thread_id: threadId,
    revision,
    ...overrides,
  }
}

function canonicalPresenceSync(users, overrides = {}) {
  return {
    type: "presence:sync",
    version: 1,
    event_id: "presence_sync:channel:7:1",
    occurred_at: "2026-08-27T00:00:00Z",
    buffer_id: "channel:7",
    server_connection_id: 42,
    channel_membership_id: 7,
    users,
    ...overrides,
  }
}

function canonicalPresenceDiff(diff, overrides = {}) {
  return {
    type: "presence:diff",
    version: 1,
    event_id: "presence_diff:channel:7:1",
    occurred_at: "2026-08-27T00:00:00Z",
    buffer_id: "channel:7",
    server_connection_id: 42,
    channel_membership_id: 7,
    diff,
    ...overrides,
  }
}

function mockTopicsFetch() {
  vi.spyOn(globalThis, "fetch").mockImplementation(async (input) => {
    const path = String(input)
    return {
      ok: true,
      json: async () => path === "/api/discovery/featured_channels"
        ? {server_channels: featuredChannelFixtures}
        : {topics: topicFixtures},
    } as Response
  })
}

function joinResponse(id, channel) {
  return {
    ok: true,
    json: async () => ({
      channel: {id, connection_id: 42, channel, unread_count: 0, mention_count: 0, mention_notifications_enabled: true, notification_preference_revision: 0},
    }),
  }
}

function emptyBootstrapMessageState(buffers) {
  const entries = buffers.map((buffer) => [buffer.buffer_id, []])
  const cursorEntries = buffers.map((buffer) => [buffer.buffer_id, null])
  return {
    messages_by_buffer: Object.fromEntries(entries),
    message_cursors_by_buffer: Object.fromEntries(cursorEntries),
  }
}

function mockBootstrapFetch({
  afterMessages = [],
  bufferMessageResponses = null,
  bootstrapChannelMessages = null,
  channelMentionCount = 0,
  channelUnreadCount = 0,
  connectionStatus = "connected",
  connectionNickname = "mira",
  deleteResponse = {
    type: "server:deleted",
    version: 1,
    event_id: "server_deleted:42:1",
    occurred_at: "2026-05-13T10:00:00Z",
    server_connection_id: 42,
  },
  includeDiscovery = false,
  joinResponsePromise = null,
  joinOk = true,
  messageCursorsByBuffer = null,
  push = {configured: false, vapid_public_key: null},
  pushSubscriptionOk = true,
  serverMessages = [],
  serverNotificationsEnabled = true,
  channelNotificationsEnabled = true,
  notificationPreferenceRevision = 0,
  channelPreferenceResponsePromise = null,
} = {}) {
  let bufferMessageRequestCount = 0
  let joinRequestCount = 0

  vi.spyOn(globalThis, "fetch").mockImplementation(async (path, options = {}) => {
    if (path === "/api/push_subscriptions" && options.method === "POST") {
      const {installation_id} = JSON.parse(options.body)
      return {
        ok: pushSubscriptionOk,
        json: async () => ({subscription: {installation_id}}),
        text: async () => "push synchronization failed",
      }
    }

    if (path === "/api/channel_memberships/7/notification_preferences" && options.method === "PUT") {
      if (channelPreferenceResponsePromise) return channelPreferenceResponsePromise
      const {mention_notifications_enabled} = JSON.parse(options.body)
      return {
        ok: true,
        json: async () => ({
          preference: {
            scope: "channel",
            id: 7,
            mention_notifications_enabled,
            revision: notificationPreferenceRevision + 1,
          },
        }),
      }
    }

    if (path === "/api/connections/42/notification_preferences" && options.method === "PUT") {
      const {mention_notifications_enabled} = JSON.parse(options.body)
      return {
        ok: true,
        json: async () => ({
          preference: {
            scope: "server",
            id: 42,
            mention_notifications_enabled,
            revision: notificationPreferenceRevision + 1,
          },
        }),
      }
    }

    if (path === "/api/connections/42" && options.method === "PUT") {
      const {connection} = JSON.parse(options.body)
      return {
        ok: true,
        json: async () => ({
          connection: {
            id: 42,
            ...connection,
            status: "connected",
            mention_notifications_enabled: true,
            notification_preference_revision: 0,
            channels: [{id: 7, channel: "#testing", unread_count: channelUnreadCount, mention_count: channelMentionCount}],
          },
        }),
      }
    }

    if (path === "/api/connections/42" && options.method === "DELETE") {
      return {
        ok: true,
        json: async () => ({deleted: deleteResponse}),
      }
    }

    if (path === "/api/connections/42/channels" && options.method === "POST") {
      const {channel} = JSON.parse(options.body)

      if (Array.isArray(joinResponsePromise)) {
        const response = joinResponsePromise[joinRequestCount]
        joinRequestCount += 1
        return response
      }

      if (joinResponsePromise) return joinResponsePromise
      if (!joinOk) return {ok: false, json: async () => ({error: "join_failed"})}

      return {
        ok: true,
        json: async () => ({
          channel: {
            id: 12,
            connection_id: 42,
            channel,
            unread_count: 0,
            mention_count: 0,
            mention_notifications_enabled: true,
            notification_preference_revision: 0,
          },
        }),
      }
    }

    if (includeDiscovery && path === "/api/discovery/server_channels") {
      return {
        ok: true,
        json: async () => ({
          server_channels: [
            {
              id: 501,
              name: "#testing",
              topic: "Existing channel",
              user_count: 42,
              network_id: 9,
              network_name: "Local IRC",
              server_host: "127.0.0.1",
              server_port: 6669,
              use_tls: false,
            },
          ],
        }),
      }
    }

    if (includeDiscovery && path === "/api/discovery/server_channels/501/join" && options.method === "POST") {
      return {
        ok: true,
        json: async () => ({
          connection: {id: 42, name: "local", host: "127.0.0.1", port: 6669, use_tls: false, nickname: "mira", status: "connected", mention_notifications_enabled: true, notification_preference_revision: 0},
          buffer: {buffer_id: "channel:7", buffer_type: "channel", server_connection_id: 42, channel_membership_id: 7, title: "#testing", subtitle: "Existing channel", status: "connected", unread_count: 0, mention_count: 0, mention_notifications_enabled: true, notification_preference_revision: 0},
        }),
      }
    }

    if (String(path).startsWith("/api/buffer_messages") && String(path).includes("before=99")) {
      return {
        ok: true,
        json: async () => ({
          messages: [
            canonicalMessage({
              id: 50,
              buffer_id: "channel:7",
              nick: "mira",
              body: "older from history",
              kind: "message",
              mentioned: false,
              occurred_at: "2026-05-13T09:30:00Z",
            }),
          ],
        }),
      }
    }

    if (String(path).startsWith("/api/buffer_messages")) {
      const messagesOrPromise = bufferMessageResponses
        ? bufferMessageResponses[Math.min(bufferMessageRequestCount++, bufferMessageResponses.length - 1)] || []
        : afterMessages

      return {
        ok: true,
        json: async () => ({
          messages: (await Promise.resolve(messagesOrPromise)).map(canonicalMessage),
        }),
      }
    }

    if (path === "/api/bootstrap") {
      const channelMessages = (bootstrapChannelMessages || [
        canonicalMessage({
          id: 99,
          buffer_id: "channel:7",
          nick: "akash",
          body: "loaded from bootstrap",
          kind: "message",
          mentioned: false,
          occurred_at: "2026-05-13T10:00:00Z",
        }),
      ]).map(canonicalMessage)
      const latestChannelMessage = channelMessages[channelMessages.length - 1]

      return {
        ok: true,
        json: async () => ({
          user: {id: 1, email: "mira@example.com", message_retention_days: 3},
          push: {
            configured: false,
            vapid_public_key: null,
            session_generation: "test-session",
            session_installation_id: null,
            session_registration_confirmed: false,
            ...push,
          },
          server_time: "2026-05-13T10:00:00Z",
          command_catalog: [
            {name: "/join", usage: "/join #channel", description: "Join a channel", required_permission: "user", contexts: ["server", "channel"], availability: "enabled", examples: ["/join #testing"]},
            {name: "/list", usage: "/list", description: "Browse channels", required_permission: "user", contexts: ["server", "channel"], availability: "enabled", examples: ["/list"]},
            {name: "/me", usage: "/me action", description: "Send an action", required_permission: "user", contexts: ["channel"], availability: "enabled", examples: ["/me waves"]},
          ],
          connections: [
            {
              id: 42,
              name: "local",
              host: "127.0.0.1",
              port: 6669,
              use_tls: false,
              nickname: connectionNickname,
              status: connectionStatus,
              mention_notifications_enabled: serverNotificationsEnabled,
              notification_preference_revision: notificationPreferenceRevision,
              channels: [7],
            },
          ],
          direct_message_tombstones: [],
          buffers: [
            {
              buffer_id: "server:42",
              buffer_type: "server",
              server_connection_id: 42,
              title: "127.0.0.1",
              subtitle: "local",
              status: connectionStatus,
              unread_count: 0,
              mention_count: 0,
              mention_notifications_enabled: serverNotificationsEnabled,
              notification_preference_revision: notificationPreferenceRevision,
            },
            {
              buffer_id: "channel:7",
              buffer_type: "channel",
              server_connection_id: 42,
              channel_membership_id: 7,
              title: "#testing",
              subtitle: "on 127.0.0.1",
              status: connectionStatus,
              unread_count: channelUnreadCount,
              mention_count: channelMentionCount,
              mention_notifications_enabled: channelNotificationsEnabled,
              notification_preference_revision: notificationPreferenceRevision,
            },
          ],
          active_buffer_id: "channel:7",
          messages_by_buffer: {
            "server:42": serverMessages.map(canonicalMessage),
            "channel:7": channelMessages,
          },
          message_cursors_by_buffer: messageCursorsByBuffer || {
            "server:42": serverMessages[serverMessages.length - 1]?.id || null,
            "channel:7": latestChannelMessage?.id || null,
          },
          users_by_buffer: {"channel:7": []},
          topics: topicFixtures,
        }),
      }
    }

    return {
      ok: true,
      json: async () => ({topics: topicFixtures}),
    }
  })
}

function mockDiscoveryFetch() {
  const channel = {
    id: 501,
    name: "#backend",
    topic: "Backend implementation work.",
    user_count: 86,
    network_id: 9,
    network_name: "Local IRC",
    server_host: "127.0.0.1",
    server_port: 6669,
    use_tls: false,
  }

  vi.spyOn(globalThis, "fetch").mockImplementation(async (path, options = {}) => {
    if (path === "/api/bootstrap") {
      return {ok: true, json: async () => ({connections: [], buffers: [], command_catalog: [], direct_message_tombstones: [], messages_by_buffer: {}, message_cursors_by_buffer: {}, users_by_buffer: {}, topics: [], push: {configured: false, vapid_public_key: null, session_generation: "test-session", session_installation_id: null, session_registration_confirmed: false}})}
    }

    if (path === "/api/discovery/server_channels") {
      return {ok: true, json: async () => ({server_channels: [channel]})}
    }

    if (path === "/api/discovery/server_channels/501/join" && options.method === "POST") {
      return {
        ok: true,
        json: async () => ({
          connection: {id: 55, name: "Local IRC", host: "127.0.0.1", port: 6669, use_tls: false, nickname: "mira", status: "connected", mention_notifications_enabled: true, notification_preference_revision: 0},
          buffer: {buffer_id: "channel:88", buffer_type: "channel", server_connection_id: 55, channel_membership_id: 88, title: "#backend", subtitle: "Backend implementation work.", status: "connected", unread_count: 0, mention_count: 0, mention_notifications_enabled: true, notification_preference_revision: 0},
        }),
      }
    }

    return {ok: true, json: async () => ({topics: []})}
  })
}

function mockResolvedLocalTopicFetch() {
  const topics = [
    {
      id: 101,
      name: "#elixir",
      description: "Phoenix, OTP, releases, and production Elixir help.",
      server_host: "127.0.0.1",
      server_port: 6669,
      use_tls: false,
      channel: "#elixir",
    },
  ]

  vi.spyOn(globalThis, "fetch").mockImplementation(async (path) => {
    if (path === "/api/bootstrap") {
      return {
        ok: true,
        json: async () => ({
          connections: [],
          buffers: [],
          command_catalog: [],
          direct_message_tombstones: [],
          messages_by_buffer: {},
          message_cursors_by_buffer: {},
          users_by_buffer: {},
          topics: [],
          push: {configured: false, vapid_public_key: null, session_generation: "test-session", session_installation_id: null, session_registration_confirmed: false},
        }),
      }
    }

    if (path === "/api/topics/101/join") {
      return {
        ok: true,
        json: async () => ({
          topic: topics[0],
          connection: {
            id: 55,
            name: "127.0.0.1",
            host: "127.0.0.1",
            port: 6669,
            use_tls: false,
            nickname: "mira",
            status: "connected",
            mention_notifications_enabled: true,
            notification_preference_revision: 0,
          },
          buffer: {
            buffer_id: "channel:88",
            buffer_type: "channel",
            server_connection_id: 55,
            channel_membership_id: 88,
            title: "#elixir",
            subtitle: "on 127.0.0.1",
            status: "connected",
            unread_count: 0,
            mention_count: 0,
            mention_notifications_enabled: true,
            notification_preference_revision: 0,
          },
        }),
      }
    }

    return {
      ok: true,
      json: async () => ({topics}),
    }
  })
}

function mockManualJoinFetch() {
  vi.spyOn(globalThis, "fetch").mockImplementation(async (path, options = {}) => {
    if (path === "/api/bootstrap") {
      return {
        ok: true,
        json: async () => ({
          connections: [],
          buffers: [],
          command_catalog: [],
          direct_message_tombstones: [],
          messages_by_buffer: {},
          message_cursors_by_buffer: {},
          users_by_buffer: {},
          topics: topicFixtures,
          push: {configured: false, vapid_public_key: null, session_generation: "test-session", session_installation_id: null, session_registration_confirmed: false},
        }),
      }
    }

    if (path === "/api/connections" && options.method === "POST") {
      return {
        ok: true,
        json: async () => ({
          connection: {
            id: 90,
            name: "irc.example.net",
            host: "irc.example.net",
            port: 6669,
            use_tls: false,
            nickname: "mira",
            status: "connected",
            mention_notifications_enabled: true,
            notification_preference_revision: 0,
          },
        }),
      }
    }

    if (path === "/api/connections/90/channels" && options.method === "POST") {
      const {channel} = JSON.parse(options.body)
      const id = channel === "#music" ? 91 : 92

      return {
        ok: true,
        json: async () => ({
          channel: {
            id,
            connection_id: 90,
            channel,
            unread_count: 0,
            mention_count: 0,
            mention_notifications_enabled: true,
            notification_preference_revision: 0,
          },
        }),
      }
    }

    return {
      ok: true,
      json: async () => ({topics: topicFixtures}),
    }
  })
}

function fakeRealtimeClient(pushImpl) {
  const client = {
    connect: vi.fn(() => client),
    disconnect: vi.fn(),
    reconnect: vi.fn(() => client),
    push: pushImpl,
  }

  return client
}

function refreshAccountMessages(postMessage) {
  return postMessage.mock.calls.filter(([message]) => message?.type === "notification:refresh-account")
}

function installSubscribedNotificationBrowser(userId = "1") {
  const originalNotification = window.Notification
  const originalPushManager = window.PushManager
  const originalServiceWorker = navigator.serviceWorker
  const installationStorageKey = "topics-club.notification-installation"
  const originalInstallation = localStorage.getItem(installationStorageKey)
  const NotificationMock = vi.fn()
  NotificationMock.permission = "granted"
  NotificationMock.requestPermission = vi.fn().mockResolvedValue("granted")
  const subscription = {
    toJSON: () => ({
      endpoint: "https://push.example.test/subscription",
      expirationTime: null,
      keys: {p256dh: "p256dh", auth: "auth"},
    }),
  }
  const registration = {
    pushManager: {
      getSubscription: vi.fn().mockResolvedValue(subscription),
      subscribe: vi.fn(),
    },
  }

  Object.defineProperty(window, "Notification", {value: NotificationMock, configurable: true})
  Object.defineProperty(window, "PushManager", {value: vi.fn(), configurable: true})
  Object.defineProperty(navigator, "serviceWorker", {
    value: {
      ready: Promise.resolve(registration),
      addEventListener: vi.fn(),
      removeEventListener: vi.fn(),
    },
    configurable: true,
  })
  localStorage.setItem(
    installationStorageKey,
    JSON.stringify({installation_id: "browser-installation", user_id: userId})
  )

  return () => {
    if (originalNotification) {
      Object.defineProperty(window, "Notification", {value: originalNotification, configurable: true})
    } else {
      delete window.Notification
    }
    if (originalPushManager) {
      Object.defineProperty(window, "PushManager", {value: originalPushManager, configurable: true})
    } else {
      delete window.PushManager
    }
    if (originalServiceWorker) {
      Object.defineProperty(navigator, "serviceWorker", {value: originalServiceWorker, configurable: true})
    } else {
      delete navigator.serviceWorker
    }
    if (originalInstallation === null) {
      localStorage.removeItem(installationStorageKey)
    } else {
      localStorage.setItem(installationStorageKey, originalInstallation)
    }
  }
}

function directMessageApiClient() {
  return {
    topics: vi.fn().mockResolvedValue({topics: []}),
    bufferMessages: vi.fn().mockResolvedValue({messages: []}),
    bootstrap: vi.fn().mockResolvedValue({
      user: {id: 1, email: "mira@example.com"},
      push: {configured: false, vapid_public_key: null, session_generation: "test-session", session_installation_id: null, session_registration_confirmed: false},
      direct_message_tombstones: [],
      connections: [
        {id: 1, name: "Old Network", host: "irc.old.test", nickname: "mira", status: "connected", mention_notifications_enabled: true, notification_preference_revision: 0},
        {id: 2, name: "New Network", host: "irc.new.test", nickname: "mira", status: "connected", mention_notifications_enabled: true, notification_preference_revision: 0},
      ],
      buffers: [
        {buffer_id: "server:1", buffer_type: "server", server_connection_id: 1, title: "irc.old.test", mention_notifications_enabled: true, notification_preference_revision: 0},
        {buffer_id: "channel:4", buffer_type: "channel", server_connection_id: 1, channel_membership_id: 4, title: "#zulu", mention_notifications_enabled: true, notification_preference_revision: 0},
        directBufferRecord(9, "Zed", {unread_count: 2, account: "zed-account"}),
        {buffer_id: "channel:3", buffer_type: "channel", server_connection_id: 1, channel_membership_id: 3, title: "#alpha", mention_notifications_enabled: true, notification_preference_revision: 0},
        directBufferRecord(8, "akash"),
        {buffer_id: "server:2", buffer_type: "server", server_connection_id: 2, title: "irc.new.test", mention_notifications_enabled: true, notification_preference_revision: 0},
      ],
      active_buffer_id: "direct:9",
      messages_by_buffer: {
        "server:1": [],
        "channel:4": [],
        "direct:9": [canonicalMessage({
          id: 31,
          buffer_id: "direct:9",
          nick: "Zed",
          body: "private hello",
        })],
        "channel:3": [],
        "direct:8": [],
        "server:2": [],
      },
      message_cursors_by_buffer: {
        "server:1": null,
        "channel:4": null,
        "direct:9": 31,
        "channel:3": null,
        "direct:8": null,
        "server:2": null,
      },
      users_by_buffer: {"channel:3": [], "channel:4": []},
      command_catalog: [{name: "/msg", usage: "/msg nick message", description: "Send a private message", required_permission: "user", contexts: ["channel"], availability: "enabled", examples: ["/msg akash hello"]}],
      topics: [],
    }),
  }
}

describe("TopicsClubApp UI prototype", () => {
  test("caps rendered messages only while the reader is near the bottom", () => {
    const messages = Array.from({length: 6}, (_, index) => ({id: index + 1, body: `message ${index + 1}`}))

    expect(visibleTimelineMessages(messages, false, 3).map((message) => message.id)).toEqual([4, 5, 6])
    expect(visibleTimelineMessages(messages, true, 3).map((message) => message.id)).toEqual([1, 2, 3, 4, 5, 6])
  })

  test("trims stored timeline messages only when the reader is at the bottom", () => {
    const messages = Array.from({length: 3}, (_, index) => ({id: index + 1, body: `message ${index + 1}`}))
    const nextMessage = {id: 4, body: "message 4"}

    expect(appendTimelineMessage(messages, nextMessage, false, 3).map((message) => message.id)).toEqual([2, 3, 4])
    expect(appendTimelineMessage(messages, nextMessage, true, 3).map((message) => message.id)).toEqual([1, 2, 3, 4])
    expect(trimMessagesToLimit([...messages, nextMessage], 3).map((message) => message.id)).toEqual([2, 3, 4])
  })

  test("appends mentions with one separator and one trailing space", () => {
    expect(appendMention("", "akash")).toBe("akash ")
    expect(appendMention("hello", "akash")).toBe("hello akash ")
    expect(appendMention("hello   ", "akash")).toBe("hello akash ")
  })

  test("adds a clicked message nick to the current draft and restores composer focus", async () => {
    const user = userEvent.setup()
    mockBootstrapFetch()

    render(
      <TopicsClubApp
        currentUser={{id: 1, email: "mira@example.com"}}
        developerOauth={true}
      />
    )

    expect(await screen.findByRole("heading", {name: "#testing"})).toBeInTheDocument()
    const composer = screen.getByLabelText("Message composer")
    await user.type(composer, "hello")
    await user.click(screen.getByRole("button", {name: "Mention akash"}))

    expect(composer).toHaveValue("hello akash ")
    await waitFor(() => expect(composer).toHaveFocus())
  })

  test("loads older channel history when scrolling near the top", async () => {
    mockBootstrapFetch()

    render(<TopicsClubApp currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}} developerOauth={true} />)

    expect(await screen.findByText("loaded from bootstrap")).toBeInTheDocument()

    const scrollback = document.getElementById("chat-scrollback")
    Object.defineProperty(scrollback, "scrollHeight", {value: 1000, configurable: true})
    Object.defineProperty(scrollback, "clientHeight", {value: 500, configurable: true})
    Object.defineProperty(scrollback, "scrollTop", {value: 40, writable: true, configurable: true})

    fireEvent.scroll(scrollback)

    expect(await screen.findByText("older from history")).toBeInTheDocument()
    expect(globalThis.fetch).toHaveBeenCalledWith(
      "/api/buffer_messages?limit=50&before=99&buffer_id=channel%3A7",
      expect.objectContaining({credentials: "same-origin"})
    )
  })

  test("shows featured discovery channels and one Google sign-in action", async () => {
    render(
      <TopicsClubApp
        currentUser={null}
        developerOauth={true}
        initialFeaturedChannels={featuredChannelFixtures}
      />
    )

    expect(await screen.findByRole("heading", {name: "Featured channels"})).toBeInTheDocument()
    expect(screen.getByRole("heading", {name: "#ruby"})).toBeInTheDocument()
    expect(screen.getByRole("heading", {name: "#python"})).toBeInTheDocument()
    expect(screen.getByRole("heading", {name: "#linux"})).toBeInTheDocument()
    expect(screen.getByRole("link", {name: "Continue with Google"})).toHaveAttribute("href", "/auth/google")
    expect(screen.queryByRole("button", {name: /join/i})).not.toBeInTheDocument()
  })

  test("rejects malformed featured-channel data embedded by the server", () => {
    render(
      <TopicsClubApp
        currentUser={null}
        developerOauth={true}
        initialFeaturedChannels={[{
          id: 101,
          name: "#broken",
          topic: 42,
          user_count: 10,
          network_id: 1,
          network_name: "Example IRC",
          server_host: "irc.example.test",
          server_port: 6697,
          use_tls: true,
        }] as never}
      />
    )

    expect(screen.queryByText("#broken")).not.toBeInTheDocument()
  })

  test("opens Discover after bootstrap when a signed-in user has no IRC connections", async () => {
    const apiClient = {
      topics: vi.fn().mockResolvedValue({topics: []}),
      bootstrap: vi.fn().mockResolvedValue({
        user: {id: 1, email: "mira@example.com"},
        push: {configured: false, vapid_public_key: null, session_generation: "empty-account", session_installation_id: null, session_registration_confirmed: false},
        direct_message_tombstones: [],
        connections: [],
        buffers: [],
        messages_by_buffer: {},
        message_cursors_by_buffer: {},
        users_by_buffer: {},
        command_catalog: [],
        topics: [],
      }),
      discoveryServerChannels: vi.fn().mockResolvedValue({server_channels: featuredChannelFixtures}),
      bufferMessages: vi.fn().mockResolvedValue({messages: []}),
    }

    render(<TopicsClubApp apiClient={apiClient as any} currentUser={{id: 1, email: "mira@example.com"}} developerOauth={true} />)

    expect(await screen.findByRole("heading", {name: "Find your next conversation."})).toBeInTheDocument()
    expect(apiClient.discoveryServerChannels).toHaveBeenCalledOnce()
  })

  test("opens discover and joins a backend topic in the app shell", async () => {
    const user = userEvent.setup()
    mockDiscoveryFetch()

    render(<TopicsClubApp currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}} developerOauth={true} />)

    await user.click(screen.getByRole("button", {name: /discover/i}))
    expect(screen.getByRole("heading", {name: "Find your next conversation."})).toBeInTheDocument()

    await user.click(await screen.findByRole("button", {name: /#backend/i}))

    expect(await screen.findByRole("heading", {name: "#backend"})).toBeInTheDocument()
    expect(screen.getByText("on 127.0.0.1")).toBeInTheDocument()
    expect(screen.queryByText(/placeholder chat until the IRC backend is wired/i)).not.toBeInTheDocument()
    expect(globalThis.fetch).toHaveBeenCalledWith("/api/discovery/server_channels", expect.objectContaining({credentials: "same-origin"}))
    expect(globalThis.fetch).toHaveBeenCalledWith("/api/discovery/server_channels/501/join", expect.objectContaining({method: "POST"}))
  })

  test("joins a typed channel from the current-server discover tab", async () => {
    const user = userEvent.setup()
    mockBootstrapFetch()

    render(<TopicsClubApp currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}} developerOauth={true} />)

    expect(await screen.findByRole("heading", {name: "#testing"})).toBeInTheDocument()
    await user.click(screen.getByRole("button", {name: /discover/i}))
    await user.click(screen.getByRole("tab", {name: "This server · local"}))
    await user.type(screen.getByLabelText("Channel name"), "elixir")
    await user.click(screen.getByRole("button", {name: "Join channel"}))

    expect(await screen.findByRole("heading", {name: "#elixir"})).toBeInTheDocument()
    expect(globalThis.fetch).toHaveBeenCalledWith(
      "/api/connections/42/channels",
      expect.objectContaining({method: "POST", body: JSON.stringify({channel: "#elixir"})})
    )
  })

  test("loads the authenticated chat shell from bootstrap", async () => {
    mockBootstrapFetch()

    render(<TopicsClubApp currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}} developerOauth={true} />)

    expect(await screen.findByRole("heading", {name: "#testing"})).toBeInTheDocument()
    expect(screen.getByText("loaded from bootstrap")).toBeInTheDocument()
    expect(screen.getByLabelText("Message composer").tagName).toBe("TEXTAREA")

    const nav = screen.getByRole("navigation", {name: "Joined topics"})
    expect(within(nav).getByText("local")).toBeInTheDocument()
    expect(within(nav).getByText("#testing")).toBeInTheDocument()
    expect(globalThis.fetch).toHaveBeenCalledWith("/api/bootstrap", expect.objectContaining({credentials: "same-origin"}))
  })

  test("loads a channel deep link and follows browser history between buffers", async () => {
    const user = userEvent.setup()
    window.history.replaceState(null, "", "/chat/42/%23testing")
    mockBootstrapFetch()

    render(<TopicsClubApp currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}} developerOauth={true} />)

    expect(await screen.findByRole("heading", {name: "#testing"})).toBeInTheDocument()
    expect(`${window.location.pathname}${window.location.search}`).toBe("/chat/42/%23testing")

    const nav = screen.getByRole("navigation", {name: "Joined topics"})
    await user.click(within(nav).getByText("local"))
    expect(await screen.findByRole("heading", {name: "127.0.0.1", level: 2})).toBeInTheDocument()
    expect(window.location.pathname).toBe("/chat/42")

    await user.click(within(nav).getByText("#testing"))
    expect(await screen.findByRole("heading", {name: "#testing"})).toBeInTheDocument()
    expect(window.location.pathname).toBe("/chat/42/%23testing")

    act(() => window.history.back())
    await waitFor(() => expect(window.location.pathname).toBe("/chat/42"))
    expect(await screen.findByRole("heading", {name: "127.0.0.1", level: 2})).toBeInTheDocument()
  })

  test("loads discovery routes and keeps remote search and pagination in the URL", async () => {
    const user = userEvent.setup()
    window.history.replaceState(null, "", "/chat/discover/all?p=2&q=linux")
    const apiClient = directMessageApiClient()
    apiClient.discoveryServerChannels = vi.fn(({connectionId, page = 1, query = ""} = {}) => Promise.resolve({
      page,
      page_size: 25,
      query,
      server_channels: [{
        id: `${connectionId || "all"}-${page}-${query || "all"}`,
        name: "#linux",
        topic: "Linux discussion",
        user_count: 120,
        network_id: 1,
        network_name: "Old Network",
        server_host: "irc.old.test",
        server_port: 6697,
        use_tls: true,
      }],
      total_channels: 70,
      total_pages: 3,
    }))

    render(<TopicsClubApp apiClient={apiClient as any} currentUser={{id: 1, email: "mira@example.com"}} developerOauth={true} />)

    expect(await screen.findByRole("heading", {name: "Find your next conversation."})).toBeInTheDocument()
    await waitFor(() => expect(apiClient.discoveryServerChannels).toHaveBeenCalledWith({
      connectionId: undefined,
      page: 2,
      query: "linux",
    }))
    expect(screen.getAllByText("Page 2 of 3")).toHaveLength(2)

    await user.click(screen.getAllByRole("button", {name: "Next channel page"})[0])
    await waitFor(() => expect(`${window.location.pathname}${window.location.search}`).toBe(
      "/chat/discover/all?p=3&q=linux"
    ))

    const search = screen.getByLabelText("Search public channels")
    await user.clear(search)
    await user.type(search, "beam")
    await user.click(screen.getByRole("button", {name: "Search"}))
    await waitFor(() => expect(`${window.location.pathname}${window.location.search}`).toBe(
      "/chat/discover/all?q=beam"
    ))

    await user.click(screen.getByRole("tab", {name: "This server · Old Network"}))
    await waitFor(() => expect(window.location.pathname).toBe("/chat/discover/1"))
    expect(window.location.search).toBe("")
    await waitFor(() => expect(apiClient.discoveryServerChannels).toHaveBeenCalledWith({
      connectionId: 1,
      page: 1,
      query: "",
    }))
  })

  test("renders ordered private-message navigation, unread state, and peer context", async () => {
    const apiClient = directMessageApiClient()

    render(<TopicsClubApp apiClient={apiClient as any} currentUser={{id: 1, email: "mira@example.com"}} developerOauth={true} />)

    expect(await screen.findByRole("heading", {name: "Zed"})).toBeInTheDocument()
    expect(screen.getByText("on Old Network")).toBeInTheDocument()
    expect(screen.getByRole("complementary", {name: "About Zed"})).toBeInTheDocument()
    expect(screen.getByRole("button", {name: "Block user"})).toBeInTheDocument()
    expect(screen.getByLabelText("2 unread messages from Zed")).toBeInTheDocument()

    const nav = screen.getByRole("navigation", {name: "Joined topics"})
    const copy = nav.textContent || ""
    expect(copy.indexOf("Old Network")).toBeLessThan(copy.indexOf("New Network"))
    expect(copy.indexOf("akash")).toBeLessThan(copy.indexOf("Zed"))
    expect(copy.indexOf("Zed")).toBeLessThan(copy.indexOf("#alpha"))
    expect(copy.indexOf("#alpha")).toBeLessThan(copy.indexOf("#zulu"))

    await userEvent.click(screen.getByLabelText("Show channels"))
    await userEvent.click(screen.getByLabelText("Show users"))

    const scopedControlIds = Array.from(document.querySelectorAll(
      '[id*="server-notification-bell"], [id$="direct-message-block-button"]'
    )).map((element) => element.id)

    expect(scopedControlIds).toContain("desktop-direct-message-block-button")
    expect(scopedControlIds).toContain("mobile-direct-message-block-button")
    expect(new Set(scopedControlIds).size).toBe(scopedControlIds.length)
  })

  test("updates an active private-message route when the peer changes nick", async () => {
    window.history.replaceState(null, "", "/chat/1/Zed")
    const apiClient = directMessageApiClient()
    const client = fakeRealtimeClient(vi.fn().mockResolvedValue({}))
    let realtimeHandlers

    render(
      <TopicsClubApp
        apiClient={apiClient as any}
        currentUser={{id: 1, email: "mira@example.com"}}
        developerOauth={true}
        realtimeClientFactory={({handlers}) => {
          realtimeHandlers = handlers
          return client
        }}
      />
    )

    expect(await screen.findByRole("heading", {name: "Zed"})).toBeInTheDocument()
    expect(window.location.pathname).toBe("/chat/1/Zed")

    act(() => realtimeHandlers.onDirectMessageThread(directThreadPayload({
      connection: {id: 1, name: "Old Network", host: "irc.old.test", nickname: "mira", status: "connected", mention_notifications_enabled: true, notification_preference_revision: 0},
      buffer: {buffer_id: "direct:9", buffer_type: "direct_message", server_connection_id: 1, direct_message_thread_id: 9, direct_message_revision: 2, title: "Zelda", unread_count: 2, blocked: false},
      revision: 2,
    })))

    expect(await screen.findByRole("heading", {name: "Zelda"})).toBeInTheDocument()
    expect(within(screen.getByRole("navigation", {name: "Joined topics"})).getByText("Zelda")).toBeInTheDocument()
    await waitFor(() => expect(window.location.pathname).toBe("/chat/1/Zelda"))
  })

  test("adds incoming private-message threads without stealing focus", async () => {
    mockBootstrapFetch()
    const push = vi.fn().mockResolvedValue(directThreadPayload({
      connection: {id: 42, name: "local", host: "127.0.0.1", status: "connecting", mention_notifications_enabled: true, notification_preference_revision: 0},
      buffer: {buffer_id: "direct:12", buffer_type: "direct_message", server_connection_id: 42, direct_message_thread_id: 12, direct_message_revision: 2, title: "akash", subtitle: "on 127.0.0.1", unread_count: 0, blocked: false},
      revision: 2,
    }))
    const client = fakeRealtimeClient(push)
    let realtimeHandlers

    render(
      <TopicsClubApp
        currentUser={{id: 1, email: "mira@example.com"}}
        developerOauth={true}
        realtimeClientFactory={({handlers}) => {
          realtimeHandlers = handlers
          return client
        }}
      />
    )

    expect(await screen.findByRole("heading", {name: "#testing"})).toBeInTheDocument()
    await act(async () => realtimeHandlers.onJoinOk())
    expect(screen.getByRole("button", {name: "Send"})).toBeEnabled()

    realtimeHandlers.onDirectMessageThread(directThreadPayload({
      connection: {id: 42, name: "local", host: "127.0.0.1", status: "connecting", mention_notifications_enabled: true, notification_preference_revision: 0},
      buffer: {buffer_id: "direct:12", buffer_type: "direct_message", server_connection_id: 42, direct_message_thread_id: 12, direct_message_revision: 1, title: "akash", subtitle: "on 127.0.0.1", unread_count: 1, blocked: false},
      revision: 1,
    }))
    realtimeHandlers.onBufferMessage(canonicalMessage({
      id: 88,
      buffer_id: "direct:12",
      server_connection_id: 42,
      nick: "akash",
      body: "incoming DM",
    }))

    expect(await screen.findByLabelText("1 unread message from akash")).toBeInTheDocument()
    expect(screen.getByRole("heading", {name: "#testing"})).toBeInTheDocument()

    const nav = screen.getByRole("navigation", {name: "Joined topics"})
    await userEvent.click(within(nav).getByText("akash"))
    expect(await screen.findByRole("heading", {name: "akash"})).toBeInTheDocument()
    expect(screen.getByText("incoming DM")).toBeInTheDocument()
    expect(screen.queryByText("Reconnecting...")).not.toBeInTheDocument()
    expect(screen.getByRole("button", {name: "Send"})).toBeEnabled()
    await waitFor(() => expect(push).toHaveBeenCalledWith("buffer:read", {
      buffer_id: "direct:12",
      expected_revision: 1,
    }))

    await userEvent.click(within(nav).getByText("#testing"))
    expect(await screen.findByRole("heading", {name: "#testing"})).toBeInTheDocument()
    expect(screen.queryByText("Reconnecting...")).not.toBeInTheDocument()
    expect(screen.getByRole("button", {name: "Send"})).toBeEnabled()
  })

  test("hydrates retained history when an incoming message reopens a closed private message", async () => {
    const user = userEvent.setup()
    const apiClient = directMessageApiClient()
    const retained = Array.from({length: 450}, (_, index) => canonicalMessage({
      id: 301 + index,
      buffer_id: "direct:9",
      server_connection_id: 1,
      channel_membership_id: null,
      direct_message_thread_id: 9,
      nick: "Zed",
      body: index === 449 ? "message that reopened the DM" : `retained message ${index + 1}`,
      occurred_at: new Date(Date.UTC(2026, 7, 26, 9, 0, index)).toISOString(),
    }))
    apiClient.bufferMessages = vi.fn((bufferId, params = {}) => {
      if (bufferId !== "direct:9" || params.limit !== 150) return Promise.resolve({messages: []})
      if (!params.before) return Promise.resolve({messages: retained.slice(-150)})
      const cursorIndex = retained.findIndex((message) => message.id === params.before)
      if (cursorIndex < 0) return Promise.resolve({messages: []})
      return Promise.resolve({messages: retained.slice(Math.max(0, cursorIndex - 150), cursorIndex)})
    })
    const client = fakeRealtimeClient(vi.fn().mockResolvedValue({}))
    let realtimeHandlers

    render(
      <TopicsClubApp
        apiClient={apiClient as any}
        currentUser={{id: 1, email: "mira@example.com"}}
        developerOauth={true}
        realtimeClientFactory={({handlers}) => {
          realtimeHandlers = handlers
          return client
        }}
      />
    )

    expect(await screen.findByRole("heading", {name: "Zed"})).toBeInTheDocument()
    act(() => realtimeHandlers.onDirectMessageClosed(directClosedPayload(9, 2)))
    expect(await screen.findByRole("heading", {name: "akash"})).toBeInTheDocument()

    act(() => {
      realtimeHandlers.onDirectMessageThread(directThreadPayload({
        connection: {id: 1, name: "Old Network", host: "irc.old.test", nickname: "mira", status: "connected", mention_notifications_enabled: true, notification_preference_revision: 0},
        buffer: {buffer_id: "direct:9", buffer_type: "direct_message", server_connection_id: 1, direct_message_thread_id: 9, direct_message_revision: 3, title: "Zed", unread_count: 1, blocked: false},
        revision: 3,
      }))
      realtimeHandlers.onBufferMessage(canonicalMessage({
        id: 750,
        buffer_id: "direct:9",
        server_connection_id: 1,
        channel_membership_id: null,
        direct_message_thread_id: 9,
        nick: "Zed",
        body: "message that reopened the DM",
        occurred_at: "2026-08-26T10:00:00Z",
      }))
    })

    await user.click(within(screen.getByRole("navigation", {name: "Joined topics"})).getByText("Zed"))
    expect(await screen.findByText("retained message 1")).toBeInTheDocument()
    expect(screen.getByText("retained message 449")).toBeInTheDocument()
    expect(screen.getByText("message that reopened the DM")).toBeInTheDocument()
    expect(apiClient.bufferMessages).toHaveBeenCalledWith("direct:9", {limit: 150})
    expect(apiClient.bufferMessages).toHaveBeenCalledWith("direct:9", {limit: 150, before: 601})
    expect(apiClient.bufferMessages).toHaveBeenCalledWith("direct:9", {limit: 150, before: 451})
    expect(apiClient.bufferMessages).toHaveBeenCalledWith("direct:9", {limit: 150, before: 301})
  })

  test("discards retained DM history when the thread closes during hydration", async () => {
    const user = userEvent.setup()
    const apiClient = directMessageApiClient()
    let resolveStaleHistory
    const staleHistory = new Promise((resolve) => { resolveStaleHistory = resolve })
    apiClient.bufferMessages = vi.fn((bufferId, params = {}) =>
      bufferId === "direct:9" && params.limit === 150 && !params.before
        ? staleHistory
        : Promise.resolve({messages: []})
    )
    let realtimeHandlers

    render(
      <TopicsClubApp
        apiClient={apiClient as any}
        currentUser={{id: 1, email: "mira@example.com"}}
        developerOauth={true}
        realtimeClientFactory={({handlers}) => {
          realtimeHandlers = handlers
          return fakeRealtimeClient(vi.fn().mockResolvedValue({}))
        }}
      />
    )

    expect(await screen.findByRole("heading", {name: "Zed"})).toBeInTheDocument()
    act(() => realtimeHandlers.onDirectMessageClosed(directClosedPayload(9, 2)))
    act(() => realtimeHandlers.onDirectMessageThread(directThreadPayload({
      connection: {id: 1, name: "Old Network", host: "irc.old.test", nickname: "mira", status: "connected", mention_notifications_enabled: true, notification_preference_revision: 0},
      buffer: {buffer_id: "direct:9", buffer_type: "direct_message", server_connection_id: 1, direct_message_thread_id: 9, direct_message_revision: 3, title: "Zed", unread_count: 1, blocked: false},
      revision: 3,
    })))
    await waitFor(() => expect(apiClient.bufferMessages).toHaveBeenCalledWith("direct:9", {limit: 150}))
    act(() => realtimeHandlers.onDirectMessageClosed(directClosedPayload(9, 4)))
    await act(async () => resolveStaleHistory({messages: [canonicalMessage({
      id: 601,
      buffer_id: "direct:9",
      server_connection_id: 1,
      channel_membership_id: null,
      direct_message_thread_id: 9,
      nick: "Zed",
      body: "stale retained message",
    })]}))

    apiClient.bufferMessages.mockImplementation(() => Promise.resolve({messages: []}))

    act(() => realtimeHandlers.onDirectMessageThread(directThreadPayload({
      connection: {id: 1, name: "Old Network", host: "irc.old.test", nickname: "mira", status: "connected", mention_notifications_enabled: true, notification_preference_revision: 0},
      buffer: {buffer_id: "direct:9", buffer_type: "direct_message", server_connection_id: 1, direct_message_thread_id: 9, direct_message_revision: 5, title: "Zed", unread_count: 1, blocked: false},
      revision: 5,
    })))

    await user.click(await within(screen.getByRole("navigation", {name: "Joined topics"})).findByText("Zed"))
    expect(await screen.findByRole("heading", {name: "Zed"})).toBeInTheDocument()
    expect(screen.queryByText("stale retained message")).not.toBeInTheDocument()
  })

  test("retries reopened DM hydration requested during an in-flight mark-read revision", async () => {
    const user = userEvent.setup()
    const seedClient = directMessageApiClient()
    const initial = await seedClient.bootstrap()
    initial.active_buffer_id = "direct:8"
    initial.buffers.find((buffer) => buffer.buffer_id === "direct:9").unread_count = 0
    let rejectHistory
    const failingHistory = new Promise((_resolve, reject) => { rejectHistory = reject })
    let historyAttempts = 0
    const apiClient = {
      ...seedClient,
      bootstrap: vi.fn().mockResolvedValue(initial),
      bufferMessages: vi.fn().mockResolvedValue({messages: []}),
    }
    const push = vi.fn((event) => event === "buffer:read"
      ? Promise.resolve(directThreadPayload({
          connection: {id: 1, name: "Old Network", host: "irc.old.test", nickname: "mira", status: "connected", mention_notifications_enabled: true, notification_preference_revision: 0},
          buffer: {buffer_id: "direct:9", buffer_type: "direct_message", server_connection_id: 1, direct_message_thread_id: 9, direct_message_revision: 4, title: "Zed", unread_count: 0, blocked: false},
          revision: 4,
        }))
      : Promise.resolve({}))
    let realtimeHandlers

    render(
      <TopicsClubApp
        apiClient={apiClient as any}
        currentUser={{id: 1, email: "mira@example.com"}}
        developerOauth={true}
        realtimeClientFactory={({handlers}) => {
          realtimeHandlers = handlers
          return fakeRealtimeClient(push)
        }}
      />
    )

    expect(await screen.findByRole("heading", {name: "akash"})).toBeInTheDocument()
    await waitFor(() => expect(apiClient.bufferMessages).toHaveBeenCalled())
    apiClient.bufferMessages.mockImplementation((bufferId, params = {}) =>
      bufferId !== "direct:9" || params.limit !== 150
        ? Promise.resolve({messages: []})
        : ++historyAttempts === 1
          ? failingHistory
          : Promise.resolve({messages: [canonicalMessage({
              id: 801,
              buffer_id: "direct:9",
              server_connection_id: 1,
              channel_membership_id: null,
              direct_message_thread_id: 9,
              nick: "Zed",
              body: "history survived mark read",
            })]})
    )
    act(() => realtimeHandlers.onDirectMessageClosed(directClosedPayload(9, 2)))
    act(() => realtimeHandlers.onDirectMessageThread(directThreadPayload({
      connection: {id: 1, name: "Old Network", host: "irc.old.test", nickname: "mira", status: "connected", mention_notifications_enabled: true, notification_preference_revision: 0},
      buffer: {buffer_id: "direct:9", buffer_type: "direct_message", server_connection_id: 1, direct_message_thread_id: 9, direct_message_revision: 3, title: "Zed", unread_count: 1, blocked: false},
      revision: 3,
    })))
    await waitFor(() => expect(apiClient.bufferMessages).toHaveBeenCalledWith("direct:9", {limit: 150}))

    await user.click(within(screen.getByRole("navigation", {name: "Joined topics"})).getByText("Zed"))
    await waitFor(() => expect(push).toHaveBeenCalledWith("buffer:read", {
      buffer_id: "direct:9",
      expected_revision: 3,
    }))
    await act(async () => rejectHistory(new Error("first history request failed")))

    expect(await screen.findByText("history survived mark read")).toBeInTheDocument()
    expect(historyAttempts).toBe(2)
  })

  test("hydrates a reopened DM installed by an in-flight reconnect bootstrap", async () => {
    const seedClient = directMessageApiClient()
    const seeded = await seedClient.bootstrap()
    const initial = structuredClone(seeded)
    initial.buffers = initial.buffers.filter((buffer) => buffer.buffer_id !== "direct:9")
    delete initial.messages_by_buffer["direct:9"]
    delete initial.message_cursors_by_buffer["direct:9"]
    initial.active_buffer_id = "direct:8"

    const refreshed = structuredClone(seeded)
    const reopened = refreshed.buffers.find((buffer) => buffer.buffer_id === "direct:9")
    reopened.direct_message_revision = 3
    reopened.unread_count = 1
    refreshed.active_buffer_id = "direct:8"
    refreshed.messages_by_buffer["direct:9"] = [canonicalMessage({
      id: 902,
      buffer_id: "direct:9",
      server_connection_id: 1,
      channel_membership_id: null,
      direct_message_thread_id: 9,
      nick: "Zed",
      body: "latest bootstrap DM",
    })]
    refreshed.message_cursors_by_buffer["direct:9"] = 902

    let resolveRefresh
    const refresh = new Promise((resolve) => { resolveRefresh = resolve })
    const apiClient = {
      ...seedClient,
      bootstrap: vi.fn().mockResolvedValueOnce(initial).mockReturnValueOnce(refresh),
      bufferMessages: vi.fn((bufferId, params = {}) => Promise.resolve({
        messages: bufferId === "direct:9" && params.limit === 150
          ? [canonicalMessage({
              id: 901,
              buffer_id: "direct:9",
              server_connection_id: 1,
              channel_membership_id: null,
              direct_message_thread_id: 9,
              nick: "Zed",
              body: "older than bootstrap window",
            })]
          : [],
      })),
    }
    let realtimeHandlers

    render(
      <TopicsClubApp
        apiClient={apiClient as any}
        currentUser={{id: 1, email: "mira@example.com"}}
        developerOauth={true}
        realtimeClientFactory={({handlers}) => {
          realtimeHandlers = handlers
          return fakeRealtimeClient(vi.fn().mockResolvedValue({}))
        }}
      />
    )

    expect(await screen.findByRole("heading", {name: "akash"})).toBeInTheDocument()
    act(() => realtimeHandlers.onJoinOk())
    act(() => realtimeHandlers.onDirectMessageThread(directThreadPayload({
      connection: {id: 1, name: "Old Network", host: "irc.old.test", nickname: "mira", status: "connected", mention_notifications_enabled: true, notification_preference_revision: 0},
      buffer: {buffer_id: "direct:9", buffer_type: "direct_message", server_connection_id: 1, direct_message_thread_id: 9, direct_message_revision: 3, title: "Zed", unread_count: 1, blocked: false},
      revision: 3,
    })))
    await act(async () => resolveRefresh(refreshed))

    await waitFor(() => expect(apiClient.bufferMessages).toHaveBeenCalledWith("direct:9", {limit: 150}))
    await userEvent.click(within(screen.getByRole("navigation", {name: "Joined topics"})).getByText("Zed"))
    expect(await screen.findByText("older than bootstrap window")).toBeInTheDocument()
    expect(screen.getByText("latest bootstrap DM")).toBeInTheDocument()
  })

  test("opens a notification DM after its authoritative thread arrives", async () => {
    const user = userEvent.setup()
    const seedClient = directMessageApiClient()
    const initial = await seedClient.bootstrap()
    const apiClient = {
      ...seedClient,
      bootstrap: vi.fn().mockResolvedValue(initial),
      bufferMessages: vi.fn().mockResolvedValue({messages: []}),
    }
    const client = fakeRealtimeClient(vi.fn())
    const listeners = new Map<string, Set<(event: any) => void>>()
    const postMessage = vi.fn()
    const originalServiceWorker = navigator.serviceWorker
    let realtimeHandlers
    let rendered

    Object.defineProperty(navigator, "serviceWorker", {
      value: {
        ready: Promise.resolve({active: {postMessage}}),
        controller: null,
        addEventListener: (type, listener) => {
          const current = listeners.get(type) || new Set()
          current.add(listener)
          listeners.set(type, current)
        },
        removeEventListener: (type, listener) => listeners.get(type)?.delete(listener),
      },
      configurable: true,
    })

    try {
      rendered = render(
        <TopicsClubApp
          apiClient={apiClient as any}
          currentUser={{id: 1, email: "mira@example.com"}}
          developerOauth={true}
          realtimeClientFactory={({handlers}) => {
            realtimeHandlers = handlers
            return client
          }}
        />
      )

      expect(await screen.findByRole("heading", {name: "Zed"})).toBeInTheDocument()
      await waitFor(() => expect(listeners.get("message")?.size).toBe(1))
      const nav = screen.getByRole("navigation", {name: "Joined topics"})
      await user.click(within(nav).getByText("akash"))
      expect(await screen.findByRole("heading", {name: "akash"})).toBeInTheDocument()

      act(() => {
        listeners.get("message")?.forEach((listener) => listener({
          data: {
            type: "notification:navigate",
            bufferId: "direct:12",
            sessionGeneration: "test-session",
            userId: "1",
          },
        }))
      })

      await waitFor(() => expect(apiClient.bootstrap).toHaveBeenCalledTimes(2))
      expect(screen.getByRole("heading", {name: "akash"})).toBeInTheDocument()

      act(() => {
        realtimeHandlers.onDirectMessageThread(directThreadPayload({
          connection: {id: 1, name: "Old Network", host: "irc.old.test", status: "connected", mention_notifications_enabled: true, notification_preference_revision: 0},
          buffer: {buffer_id: "direct:12", buffer_type: "direct_message", server_connection_id: 1, direct_message_thread_id: 12, direct_message_revision: 1, title: "Mona", unread_count: 1, blocked: false},
          revision: 1,
        }))
      })

      expect(await screen.findByRole("heading", {name: "Mona"})).toBeInTheDocument()
    } finally {
      rendered?.unmount()
      if (originalServiceWorker) {
        Object.defineProperty(navigator, "serviceWorker", {value: originalServiceWorker, configurable: true})
      } else {
        delete navigator.serviceWorker
      }
    }
  })

  test("discards pending notification navigation when bootstrap rotates the session generation", async () => {
    const user = userEvent.setup()
    const seedClient = directMessageApiClient()
    const initial = await seedClient.bootstrap()
    const rotatedBuffers = [
      ...initial.buffers,
      directBufferRecord(12, "Mona", {unread_count: 1}),
    ]
    const rotatedSession = {
      ...initial,
      push: {...initial.push, session_generation: "session-b"},
      buffers: rotatedBuffers,
      messages_by_buffer: {...initial.messages_by_buffer, "direct:12": []},
      message_cursors_by_buffer: {...initial.message_cursors_by_buffer, "direct:12": null},
    }
    const apiClient = {
      ...seedClient,
      bootstrap: vi.fn()
        .mockResolvedValueOnce(initial)
        .mockResolvedValue(rotatedSession),
      bufferMessages: vi.fn().mockResolvedValue({messages: []}),
    }
    const client = fakeRealtimeClient(vi.fn())
    const listeners = new Map<string, Set<(event: any) => void>>()
    const originalServiceWorker = navigator.serviceWorker
    let rendered

    Object.defineProperty(navigator, "serviceWorker", {
      value: {
        ready: Promise.resolve({active: {postMessage: vi.fn()}}),
        controller: null,
        addEventListener: (type, listener) => {
          const current = listeners.get(type) || new Set()
          current.add(listener)
          listeners.set(type, current)
        },
        removeEventListener: (type, listener) => listeners.get(type)?.delete(listener),
      },
      configurable: true,
    })

    try {
      rendered = render(
        <TopicsClubApp
          apiClient={apiClient as any}
          currentUser={{id: 1, email: "mira@example.com"}}
          developerOauth={true}
          realtimeClientFactory={() => client}
        />
      )

      expect(await screen.findByRole("heading", {name: "Zed"})).toBeInTheDocument()
      await waitFor(() => expect(listeners.get("message")?.size).toBe(1))
      const nav = screen.getByRole("navigation", {name: "Joined topics"})
      await user.click(within(nav).getByText("akash"))
      expect(await screen.findByRole("heading", {name: "akash"})).toBeInTheDocument()

      act(() => {
        listeners.get("message")?.forEach((listener) => listener({
          data: {
            type: "notification:navigate",
            bufferId: "direct:12",
            sessionGeneration: "test-session",
            userId: "1",
          },
        }))
      })

      await waitFor(() => expect(apiClient.bootstrap).toHaveBeenCalledTimes(2))
      expect(await within(nav).findByText("Mona")).toBeInTheDocument()
      expect(screen.getByRole("heading", {name: "akash"})).toBeInTheDocument()
    } finally {
      rendered?.unmount()
      if (originalServiceWorker) {
        Object.defineProperty(navigator, "serviceWorker", {value: originalServiceWorker, configurable: true})
      } else {
        delete navigator.serviceWorker
      }
    }
  })

  test("discards pending notification navigation when the account generation changes", async () => {
    const seedClient = directMessageApiClient()
    const initial = await seedClient.bootstrap()
    const nextAccount = {
      ...initial,
      user: {id: 2, email: "other@example.com"},
      push: {...initial.push, session_generation: "session-b"},
      buffers: initial.buffers.map((buffer) =>
        buffer.buffer_id === "direct:9" ? directBufferRecord(9, "Bea") : buffer
      ),
    }
    const apiClient = {
      ...seedClient,
      bootstrap: vi.fn()
        .mockResolvedValueOnce(initial)
        .mockResolvedValueOnce(initial)
        .mockResolvedValue(nextAccount),
      bufferMessages: vi.fn().mockResolvedValue({messages: []}),
    }
    const client = fakeRealtimeClient(vi.fn())
    const listeners = new Map<string, Set<(event: any) => void>>()
    const originalServiceWorker = navigator.serviceWorker
    let realtimeHandlers
    let rendered

    Object.defineProperty(navigator, "serviceWorker", {
      value: {
        ready: Promise.resolve({active: {postMessage: vi.fn()}}),
        controller: null,
        addEventListener: (type, listener) => {
          const current = listeners.get(type) || new Set()
          current.add(listener)
          listeners.set(type, current)
        },
        removeEventListener: (type, listener) => listeners.get(type)?.delete(listener),
      },
      configurable: true,
    })

    try {
      rendered = render(
        <TopicsClubApp
          apiClient={apiClient as any}
          currentUser={{id: 1, email: "mira@example.com"}}
          developerOauth={true}
          realtimeClientFactory={({handlers}) => {
            realtimeHandlers = handlers
            return client
          }}
        />
      )

      expect(await screen.findByRole("heading", {name: "Zed"})).toBeInTheDocument()
      await waitFor(() => expect(listeners.get("message")?.size).toBe(1))
      act(() => {
        listeners.get("message")?.forEach((listener) => listener({
          data: {
            type: "notification:navigate",
            bufferId: "direct:12",
            sessionGeneration: "test-session",
            userId: "1",
          },
        }))
      })
      await waitFor(() => expect(apiClient.bootstrap).toHaveBeenCalledTimes(2))

      rendered.rerender(
        <TopicsClubApp
          apiClient={apiClient as any}
          currentUser={{id: 2, email: "other@example.com"}}
          developerOauth={true}
          realtimeClientFactory={({handlers}) => {
            realtimeHandlers = handlers
            return client
          }}
        />
      )
      expect(await screen.findByRole("heading", {name: "Bea"})).toBeInTheDocument()

      act(() => {
        listeners.get("message")?.forEach((listener) => listener({
          data: {
            type: "notification:navigate",
            bufferId: "direct:12",
            sessionGeneration: "test-session",
            userId: "1",
          },
        }))
        realtimeHandlers.onDirectMessageThread(directThreadPayload({
          connection: {id: 1, name: "Old Network", host: "irc.old.test", status: "connected", mention_notifications_enabled: true, notification_preference_revision: 0},
          buffer: {buffer_id: "direct:12", buffer_type: "direct_message", server_connection_id: 1, direct_message_thread_id: 12, direct_message_revision: 1, title: "Mona", unread_count: 1, blocked: false},
          revision: 1,
        }))
      })

      expect(screen.getByRole("heading", {name: "Bea"})).toBeInTheDocument()
    } finally {
      rendered?.unmount()
      if (originalServiceWorker) {
        Object.defineProperty(navigator, "serviceWorker", {value: originalServiceWorker, configurable: true})
      } else {
        delete navigator.serviceWorker
      }
    }
  })

  test("ignores a delayed private-message close older than a reopen", async () => {
    const apiClient = directMessageApiClient()
    const client = fakeRealtimeClient(vi.fn())
    let realtimeHandlers

    render(
      <TopicsClubApp
        apiClient={apiClient as any}
        currentUser={{id: 1, email: "mira@example.com"}}
        developerOauth={true}
        realtimeClientFactory={({handlers}) => {
          realtimeHandlers = handlers
          return client
        }}
      />
    )

    expect(await screen.findByRole("heading", {name: "Zed"})).toBeInTheDocument()

    act(() => {
      realtimeHandlers.onDirectMessageThread(directThreadPayload({
        connection: {id: 1, name: "Old Network", host: "irc.old.test", status: "connected", mention_notifications_enabled: true, notification_preference_revision: 0},
        buffer: {
          buffer_id: "direct:9",
          buffer_type: "direct_message",
          server_connection_id: 1,
          direct_message_thread_id: 9,
          direct_message_revision: 3,
          title: "Zed",
          subtitle: "on irc.old.test",
          unread_count: 1,
          blocked: false,
          closed_at: null,
        },
        revision: 3,
      }))
      realtimeHandlers.onDirectMessageClosed(directClosedPayload(9, 2))
    })

    expect(screen.getByRole("heading", {name: "Zed"})).toBeInTheDocument()
    expect(screen.getByLabelText("1 unread message from Zed")).toBeInTheDocument()
  })

  test("keeps a full read snapshot when an older private-message snapshot is delayed", async () => {
    const apiClient = directMessageApiClient()
    const client = fakeRealtimeClient(vi.fn())
    let realtimeHandlers

    render(
      <TopicsClubApp
        apiClient={apiClient as any}
        currentUser={{id: 1, email: "mira@example.com"}}
        developerOauth={true}
        realtimeClientFactory={({handlers}) => {
          realtimeHandlers = handlers
          return client
        }}
      />
    )

    expect(await screen.findByRole("heading", {name: "Zed"})).toBeInTheDocument()

    const connection = {id: 1, name: "Old Network", host: "irc.old.test", status: "connected", mention_notifications_enabled: true, notification_preference_revision: 0}
    act(() => {
      realtimeHandlers.onDirectMessageThread(directThreadPayload({
        connection,
        buffer: {
          buffer_id: "direct:9",
          buffer_type: "direct_message",
          server_connection_id: 1,
          direct_message_thread_id: 9,
          direct_message_revision: 3,
          title: "Zed",
          unread_count: 0,
          blocked: true,
          closed_at: null,
        },
        revision: 3,
      }))
      realtimeHandlers.onDirectMessageThread(directThreadPayload({
        connection,
        buffer: {
          buffer_id: "direct:9",
          buffer_type: "direct_message",
          server_connection_id: 1,
          direct_message_thread_id: 9,
          direct_message_revision: 2,
          title: "Zed",
          unread_count: 2,
          blocked: false,
          closed_at: null,
        },
        revision: 2,
      }))
    })

    expect(screen.getByRole("button", {name: "Unblock user"})).toBeInTheDocument()
    expect(screen.queryByLabelText("2 unread messages from Zed")).not.toBeInTheDocument()
  })

  test("seeds closed-thread tombstones before replaying realtime events", async () => {
    const seedClient = directMessageApiClient()
    const initial = await seedClient.bootstrap()
    const apiClient = {
      ...seedClient,
      bootstrap: vi.fn().mockResolvedValue({
        ...initial,
        active_buffer_id: "direct:8",
        buffers: initial.buffers.filter((buffer) => buffer.buffer_id !== "direct:9"),
        ...emptyBootstrapMessageState(
          initial.buffers.filter((buffer) => buffer.buffer_id !== "direct:9")
        ),
        direct_message_tombstones: [{
          buffer_id: "direct:9",
          server_connection_id: 1,
          direct_message_thread_id: 9,
          revision: 2,
        }],
      }),
    }
    const client = fakeRealtimeClient(vi.fn())
    let realtimeHandlers

    render(
      <TopicsClubApp
        apiClient={apiClient as any}
        currentUser={{id: 1, email: "mira@example.com"}}
        developerOauth={true}
        realtimeClientFactory={({handlers}) => {
          realtimeHandlers = handlers
          return client
        }}
      />
    )

    expect(await screen.findByRole("heading", {name: "akash"})).toBeInTheDocument()
    act(() => {
      realtimeHandlers.onDirectMessageThread(directThreadPayload({
        connection: {id: 1, name: "Old Network", host: "irc.old.test", status: "connected", mention_notifications_enabled: true, notification_preference_revision: 0},
        buffer: {
          buffer_id: "direct:9",
          buffer_type: "direct_message",
          server_connection_id: 1,
          direct_message_thread_id: 9,
          direct_message_revision: 1,
          title: "Zed",
          unread_count: 1,
          blocked: false,
          closed_at: null,
        },
        revision: 1,
      }))
    })

    const nav = screen.getByRole("navigation", {name: "Joined topics"})
    expect(within(nav).queryByText("Zed")).not.toBeInTheDocument()
    expect(screen.getByRole("heading", {name: "akash"})).toBeInTheDocument()
  })

  test("rejects malformed direct-message realtime records instead of reconstructing identifiers", async () => {
    const apiClient = directMessageApiClient()
    const client = fakeRealtimeClient(vi.fn())
    let realtimeHandlers

    render(
      <TopicsClubApp
        apiClient={apiClient as any}
        currentUser={{id: 1, email: "mira@example.com"}}
        developerOauth={true}
        realtimeClientFactory={({handlers}) => {
          realtimeHandlers = handlers
          return client
        }}
      />
    )

    expect(await screen.findByRole("heading", {name: "Zed"})).toBeInTheDocument()

    act(() => {
      realtimeHandlers.onDirectMessageThread({
        connection: {id: 1, host: "irc.old.test", mention_notifications_enabled: true, notification_preference_revision: 0},
        buffer: {
          buffer_id: "direct:12",
          buffer_type: "direct_message",
          server_connection_id: 1,
          direct_message_revision: 1,
          title: "Mona",
        },
        revision: 1,
      } as any)
      realtimeHandlers.onDirectMessageThread({
        type: "direct_message:thread",
        version: 1,
        event_id: "direct_message_thread:[:1",
        occurred_at: "2026-08-26T00:00:00Z",
        connection: {id: 1, name: "Old Network", host: "irc.old.test", status: "connected", mention_notifications_enabled: true, notification_preference_revision: 0},
        buffer: {
          buffer_id: "direct:[",
          buffer_type: "direct_message",
          server_connection_id: 1,
          direct_message_thread_id: "[",
          direct_message_revision: 1,
          title: "Regex",
          subtitle: "on irc.old.test",
          peer_nick: "Regex",
          account: null,
          hostmask: null,
          blocked: false,
          closed_at: null,
          unread_count: 0,
          mention_count: 0,
        },
        revision: 1,
      } as any)
      realtimeHandlers.onDirectMessageThread(directThreadPayload({
        connection: {id: 1, name: "Old Network", host: "irc.old.test", status: "connected", mention_notifications_enabled: true, notification_preference_revision: 0},
        buffer: {buffer_id: "direct:13", buffer_type: "direct_message", server_connection_id: 1, direct_message_thread_id: 13, direct_message_revision: 1, title: "", unread_count: 0, blocked: false},
        revision: 1,
      }))
      realtimeHandlers.onDirectMessageThread(directThreadPayload({
        connection: {id: 1, name: "Old Network", host: "irc.old.test", status: "connected", mention_notifications_enabled: true, notification_preference_revision: 0},
        buffer: {buffer_id: "direct:14", buffer_type: "direct_message", server_connection_id: 1, direct_message_thread_id: 14, direct_message_revision: 1, title: "Closed", unread_count: 0, blocked: false, closed_at: "not-a-timestamp"},
        revision: 1,
      }))
      realtimeHandlers.onDirectMessageClosed({
        buffer_id: "direct:9",
        server_connection_id: 1,
        direct_message_thread_id: 8,
        revision: 2,
      })
      realtimeHandlers.onDirectMessageClosed(directClosedPayload(9, 4, {
        event_id: "direct_message_closed:8:4",
      }))
    })

    const nav = screen.getByRole("navigation", {name: "Joined topics"})
    expect(within(nav).queryByText("Mona")).not.toBeInTheDocument()
    expect(within(nav).queryByText("Regex")).not.toBeInTheDocument()
    expect(within(nav).queryByText("Closed")).not.toBeInTheDocument()
    expect(within(nav).getByText("Zed")).toBeInTheDocument()
  })

  test("authoritatively refreshes on reconnect and replays events that arrive during refresh", async () => {
    const seedClient = directMessageApiClient()
    const initial = await seedClient.bootstrap()
    let resolveRefresh
    const refreshed = {
      ...initial,
      buffers: [
        ...initial.buffers.filter((buffer) => buffer.buffer_id !== "direct:9"),
        directBufferRecord(10, "Bella", {unread_count: 1}),
      ],
      ...emptyBootstrapMessageState([
        ...initial.buffers.filter((buffer) => buffer.buffer_id !== "direct:9"),
        directBufferRecord(10, "Bella", {unread_count: 1}),
      ]),
    }
    const apiClient = {
      ...seedClient,
      bootstrap: vi
        .fn()
        .mockResolvedValueOnce(initial)
        .mockImplementationOnce(() => new Promise((resolve) => { resolveRefresh = resolve }))
        .mockResolvedValue(refreshed),
      bufferMessages: vi.fn().mockResolvedValue({messages: []}),
    }
    const client = fakeRealtimeClient(vi.fn())
    let realtimeHandlers

    render(
      <TopicsClubApp
        apiClient={apiClient as any}
        currentUser={{id: 1, email: "mira@example.com"}}
        developerOauth={true}
        realtimeClientFactory={({handlers}) => {
          realtimeHandlers = handlers
          return client
        }}
      />
    )

    expect(await screen.findByRole("heading", {name: "Zed"})).toBeInTheDocument()
    expect(apiClient.bootstrap).toHaveBeenCalledTimes(1)

    await act(async () => realtimeHandlers.onOpen())
    expect(apiClient.bootstrap).toHaveBeenCalledTimes(1)
    await act(async () => realtimeHandlers.onJoinOk())
    expect(apiClient.bootstrap).toHaveBeenCalledTimes(2)

    act(() => {
      realtimeHandlers.onDirectMessageThread(directThreadPayload({
        connection: {id: 1, name: "Old Network", host: "irc.old.test", status: "connected", mention_notifications_enabled: true, notification_preference_revision: 0},
        buffer: {buffer_id: "direct:12", buffer_type: "direct_message", server_connection_id: 1, direct_message_thread_id: 12, direct_message_revision: 1, title: "Mona", unread_count: 1, blocked: false},
        revision: 1,
      }))
    })

    expect(screen.queryByText("Mona")).not.toBeInTheDocument()
    await act(async () => resolveRefresh(refreshed))

    const nav = screen.getByRole("navigation", {name: "Joined topics"})
    expect(await within(nav).findByText("Bella")).toBeInTheDocument()
    expect(within(nav).getByText("Mona")).toBeInTheDocument()
    expect(within(nav).queryByText("Zed")).not.toBeInTheDocument()

    act(() => realtimeHandlers.onChannelError({reason: "server restart"}))
    await act(async () => realtimeHandlers.onJoinOk())
    await waitFor(() => expect(apiClient.bootstrap).toHaveBeenCalledTimes(3))
  })

  test("reconciles known buffers before replaying events after a malformed reconnect bootstrap", async () => {
    const seedClient = directMessageApiClient()
    const initial = await seedClient.bootstrap()
    let resolveRefresh
    let serveMissedMessage = false
    const missedMessage = canonicalMessage({
      id: 32,
      buffer_id: "direct:9",
      server_connection_id: 1,
      nick: "Zed",
      body: "persisted while disconnected",
    })
    const apiClient = {
      ...seedClient,
      bootstrap: vi
        .fn()
        .mockResolvedValueOnce(initial)
        .mockImplementationOnce(() => new Promise((resolve) => { resolveRefresh = resolve })),
      bufferMessages: vi.fn().mockImplementation((bufferId) =>
        Promise.resolve({
          messages: serveMissedMessage && bufferId === "direct:9" ? [missedMessage] : [],
        })
      ),
    }
    const client = fakeRealtimeClient(vi.fn())
    let realtimeHandlers

    render(
      <TopicsClubApp
        apiClient={apiClient as any}
        currentUser={{id: 1, email: "mira@example.com"}}
        developerOauth={true}
        realtimeClientFactory={({handlers}) => {
          realtimeHandlers = handlers
          return client
        }}
      />
    )

    expect(await screen.findByRole("heading", {name: "Zed"})).toBeInTheDocument()
    await waitFor(() => {
      const calls = apiClient.bufferMessages.mock.calls
      expect(calls.filter(([_bufferId, params]) => params.limit === 50)).toHaveLength(6)
      expect(calls.filter(([_bufferId, params]) => params.limit === 150)).toHaveLength(2)
    })
    apiClient.bufferMessages.mockClear()
    serveMissedMessage = true
    await act(async () => realtimeHandlers.onOpen())
    await act(async () => realtimeHandlers.onJoinOk())

    act(() => {
      realtimeHandlers.onDirectMessageThread(directThreadPayload({
        connection: {id: 1, host: "irc.old.test", status: "connected", mention_notifications_enabled: true, notification_preference_revision: 0},
        buffer: {buffer_id: "direct:12", buffer_type: "direct_message", server_connection_id: 1, direct_message_thread_id: 12, direct_message_revision: 1, title: "Mona", blocked: false},
        revision: 1,
      }))
    })

    expect(screen.queryByText("Mona")).not.toBeInTheDocument()
    await act(async () => resolveRefresh({...initial, messages_by_buffer: {}}))

    expect(await screen.findByText("persisted while disconnected")).toBeInTheDocument()
    expect(within(screen.getByRole("navigation", {name: "Joined topics"})).getByText("Mona")).toBeInTheDocument()
    expect(apiClient.bufferMessages).toHaveBeenCalled()
  })

  test("refreshes the worker account when the same user rotates session generation", async () => {
    const seedClient = directMessageApiClient()
    const base = await seedClient.bootstrap()
    const initial = {
      ...base,
      push: {
        configured: false,
        vapid_public_key: null,
        session_generation: "session-a",
        session_installation_id: null,
        session_registration_confirmed: false,
      },
    }
    const rotated = {
      ...initial,
      push: {...initial.push, session_generation: "session-b"},
    }
    const apiClient = {
      ...seedClient,
      bootstrap: vi.fn().mockResolvedValueOnce(initial).mockResolvedValue(rotated),
      bufferMessages: vi.fn().mockResolvedValue({messages: []}),
    }
    const client = fakeRealtimeClient(vi.fn())
    const postMessage = vi.fn()
    const originalServiceWorker = navigator.serviceWorker
    let realtimeHandlers

    Object.defineProperty(navigator, "serviceWorker", {
      value: {
        ready: Promise.resolve({active: {postMessage}}),
        addEventListener: vi.fn(),
        removeEventListener: vi.fn(),
        controller: null,
      },
      configurable: true,
    })

    try {
      render(
        <TopicsClubApp
          apiClient={apiClient as any}
          currentUser={{id: 1, email: "mira@example.com"}}
          developerOauth={true}
          realtimeClientFactory={({handlers}) => {
            realtimeHandlers = handlers
            return client
          }}
        />
      )

      expect(await screen.findByRole("heading", {name: "Zed"})).toBeInTheDocument()
      await waitFor(() => expect(refreshAccountMessages(postMessage).length).toBeGreaterThanOrEqual(2))
      const beforeRotation = refreshAccountMessages(postMessage).length

      await act(async () => realtimeHandlers.onJoinOk())

      await waitFor(() => {
        expect(apiClient.bootstrap).toHaveBeenCalledTimes(2)
        expect(refreshAccountMessages(postMessage).length).toBeGreaterThan(beforeRotation)
      })
    } finally {
      if (originalServiceWorker) {
        Object.defineProperty(navigator, "serviceWorker", {value: originalServiceWorker, configurable: true})
      } else {
        delete navigator.serviceWorker
      }
    }
  })

  test("auto-opens a direct-message thread returned by msg", async () => {
    const user = userEvent.setup()
    mockBootstrapFetch()
    const push = vi.fn().mockImplementation((event) => {
      if (event !== "command:run") return Promise.resolve({})
      return Promise.resolve(directThreadPayload({
        connection: {id: 42, name: "local", host: "127.0.0.1", port: 6669, use_tls: false, nickname: "mira", status: "connected", mention_notifications_enabled: true, notification_preference_revision: 0},
        buffer: {buffer_id: "direct:12", buffer_type: "direct_message", server_connection_id: 42, direct_message_thread_id: 12, direct_message_revision: 1, title: "akash", subtitle: "on 127.0.0.1", unread_count: 0, blocked: false},
        revision: 1,
        message: canonicalMessage({id: 89, buffer_id: "direct:12", server_connection_id: 42, nick: "mira", body: "hello privately", occurred_at: "2026-08-26T00:00:00Z", occurredAt: "invalid", clientMessageId: "wire-client-id", pending: true, failed: true}),
      }))
    })
    const client = fakeRealtimeClient(push)
    let realtimeHandlers

    render(
      <TopicsClubApp
        currentUser={{id: 1, email: "mira@example.com"}}
        developerOauth={true}
        realtimeClientFactory={({handlers}) => {
          realtimeHandlers = handlers
          return client
        }}
      />
    )

    expect(await screen.findByRole("heading", {name: "#testing"})).toBeInTheDocument()
    realtimeHandlers.onJoinOk()
    await user.type(screen.getByLabelText("Message composer"), "/msg akash hello privately")
    await user.click(screen.getByRole("button", {name: "Send"}))

    expect(await screen.findByRole("heading", {name: "akash"})).toBeInTheDocument()
    expect(screen.getByText("hello privately")).toBeInTheDocument()
    expect(screen.queryByRole("button", {name: "Retry"})).not.toBeInTheDocument()
    expect(screen.getByText("hello privately").closest("div")?.querySelector("time")).toHaveAttribute("datetime", "2026-08-26T00:00:00Z")
    expect(push).toHaveBeenCalledWith("command:run", expect.objectContaining({input: "/msg akash hello privately", buffer_id: "channel:7"}))
  })

  test("rejects a msg reply whose authoritative message body does not match the command", async () => {
    const user = userEvent.setup()
    mockBootstrapFetch()
    const push = vi.fn().mockResolvedValue(directThreadPayload({
      connection: {id: 42, name: "local", host: "127.0.0.1", port: 6669, use_tls: false, nickname: "mira", status: "connected", mention_notifications_enabled: true, notification_preference_revision: 0},
      buffer: {buffer_id: "direct:12", buffer_type: "direct_message", server_connection_id: 42, direct_message_thread_id: 12, direct_message_revision: 1, title: "akash", subtitle: "on 127.0.0.1", unread_count: 0, blocked: false},
      revision: 1,
      message: canonicalMessage({id: 89, buffer_id: "direct:12", server_connection_id: 42, nick: "mira", body: "different body", occurred_at: "2026-08-26T00:00:00Z"}),
    }))
    const client = fakeRealtimeClient(push)
    let realtimeHandlers

    render(
      <TopicsClubApp
        currentUser={{id: 1, email: "mira@example.com"}}
        developerOauth={true}
        realtimeClientFactory={({handlers}) => {
          realtimeHandlers = handlers
          return client
        }}
      />
    )

    expect(await screen.findByRole("heading", {name: "#testing"})).toBeInTheDocument()
    realtimeHandlers.onJoinOk()
    const composer = screen.getByLabelText("Message composer")
    await user.type(composer, "/msg akash hello privately")
    await user.click(screen.getByRole("button", {name: "Send"}))

    expect(await screen.findByText("The IRC command could not be sent.")).toBeInTheDocument()
    expect(screen.queryByRole("heading", {name: "akash"})).not.toBeInTheDocument()
    expect(composer).toHaveValue("/msg akash hello privately")
  })

  test("blocks, unblocks, and closes a direct-message thread", async () => {
    const user = userEvent.setup()
    const apiClient = directMessageApiClient()
    let mutationRevision = 1
    const push = vi.fn().mockImplementation((event, payload) => {
      if (event === "direct_message:block") {
        mutationRevision += 1
        return Promise.resolve(directThreadPayload({
          connection: {id: 1, name: "Old Network", host: "irc.old.test", nickname: "mira", status: "connected", mention_notifications_enabled: true, notification_preference_revision: 0},
          buffer: {buffer_id: "direct:9", buffer_type: "direct_message", server_connection_id: 1, direct_message_thread_id: 9, direct_message_revision: mutationRevision, title: "Zed", subtitle: "on irc.old.test", unread_count: 0, blocked: payload.blocked, account: "zed-account"},
          revision: mutationRevision,
        }))
      }
      if (event === "direct_message:close") {
        mutationRevision += 1
        return Promise.resolve(directClosedPayload(9, mutationRevision))
      }
      return Promise.resolve({})
    })
    const client = fakeRealtimeClient(push)

    render(
      <TopicsClubApp
        apiClient={apiClient as any}
        currentUser={{id: 1, email: "mira@example.com"}}
        developerOauth={true}
        realtimeClientFactory={() => client}
      />
    )

    expect(await screen.findByRole("heading", {name: "Zed"})).toBeInTheDocument()
    await user.click(screen.getByRole("button", {name: "Block user"}))
    expect(await screen.findByRole("button", {name: "Unblock user"})).toBeInTheDocument()
    await user.click(screen.getByRole("button", {name: "Unblock user"}))
    expect(await screen.findByRole("button", {name: "Block user"})).toBeInTheDocument()

    await user.click(screen.getByRole("button", {name: "Private message actions for Zed"}))
    await user.click(screen.getByRole("menuitem", {name: "Close"}))

    expect(await screen.findByRole("heading", {name: "akash"})).toBeInTheDocument()
    expect(push).toHaveBeenCalledWith("direct_message:block", {
      buffer_id: "direct:9",
      blocked: true,
      expected_revision: 1,
    })
    expect(push).toHaveBeenCalledWith("direct_message:block", {
      buffer_id: "direct:9",
      blocked: false,
      expected_revision: 2,
    })
    expect(push).toHaveBeenCalledWith("direct_message:close", {
      buffer_id: "direct:9",
      expected_revision: 3,
    })
  })

  test("refreshes an updated open thread after a stale direct-message read", async () => {
    const seedClient = directMessageApiClient()
    const initial = await seedClient.bootstrap()
    const refreshed = {
      ...initial,
      buffers: initial.buffers.map((buffer) =>
        buffer.buffer_id === "direct:9"
          ? directBufferRecord(9, "Zed Renamed", {
              account: "zed-account",
              direct_message_revision: 2,
              unread_count: 0,
            })
          : buffer
      ),
    }
    const apiClient = {
      ...seedClient,
      bootstrap: vi.fn().mockResolvedValueOnce(initial).mockResolvedValue(refreshed),
    }
    const push = vi.fn().mockRejectedValue({reason: "stale_direct_message"})

    render(
      <TopicsClubApp
        apiClient={apiClient as any}
        currentUser={{id: 1, email: "mira@example.com"}}
        developerOauth={true}
        realtimeClientFactory={() => fakeRealtimeClient(push)}
      />
    )

    expect(await screen.findByRole("heading", {name: "Zed Renamed"})).toBeInTheDocument()
    expect(apiClient.bootstrap).toHaveBeenCalledTimes(2)
    expect(push).toHaveBeenCalledWith("buffer:read", {
      buffer_id: "direct:9",
      expected_revision: 1,
    })
  })

  test("refreshes an updated open thread after a stale direct-message block", async () => {
    const user = userEvent.setup()
    const seedClient = directMessageApiClient()
    const seeded = await seedClient.bootstrap()
    const initial = {
      ...seeded,
      buffers: seeded.buffers.map((buffer) =>
        buffer.buffer_id === "direct:9" ? {...buffer, unread_count: 0} : buffer
      ),
    }
    const refreshed = {
      ...initial,
      buffers: initial.buffers.map((buffer) =>
        buffer.buffer_id === "direct:9"
          ? {...buffer, blocked: true, direct_message_revision: 2}
          : buffer
      ),
    }
    const apiClient = {
      ...seedClient,
      bootstrap: vi.fn().mockResolvedValueOnce(initial).mockResolvedValue(refreshed),
    }
    const push = vi.fn().mockRejectedValue({reason: "stale_direct_message"})

    render(
      <TopicsClubApp
        apiClient={apiClient as any}
        currentUser={{id: 1, email: "mira@example.com"}}
        developerOauth={true}
        realtimeClientFactory={() => fakeRealtimeClient(push)}
      />
    )

    await user.click(await screen.findByRole("button", {name: "Block user"}))

    expect(await screen.findByRole("button", {name: "Unblock user"})).toBeInTheDocument()
    expect(apiClient.bootstrap).toHaveBeenCalledTimes(2)
    expect(push).toHaveBeenCalledWith("direct_message:block", {
      buffer_id: "direct:9",
      blocked: true,
      expected_revision: 1,
    })
  })

  test("refreshes a closed-thread tombstone after a stale direct-message close", async () => {
    const user = userEvent.setup()
    const seedClient = directMessageApiClient()
    const seeded = await seedClient.bootstrap()
    const initial = {
      ...seeded,
      buffers: seeded.buffers.map((buffer) =>
        buffer.buffer_id === "direct:9" ? {...buffer, unread_count: 0} : buffer
      ),
    }
    const refreshed = {
      ...initial,
      active_buffer_id: "direct:8",
      buffers: initial.buffers.filter((buffer) => buffer.buffer_id !== "direct:9"),
      ...emptyBootstrapMessageState(
        initial.buffers.filter((buffer) => buffer.buffer_id !== "direct:9")
      ),
      direct_message_tombstones: [
        {
          buffer_id: "direct:9",
          server_connection_id: 1,
          direct_message_thread_id: 9,
          revision: 2,
        },
      ],
    }
    const apiClient = {
      ...seedClient,
      bootstrap: vi.fn().mockResolvedValueOnce(initial).mockResolvedValue(refreshed),
    }
    const push = vi.fn().mockRejectedValue({reason: "stale_direct_message"})

    render(
      <TopicsClubApp
        apiClient={apiClient as any}
        currentUser={{id: 1, email: "mira@example.com"}}
        developerOauth={true}
        realtimeClientFactory={() => fakeRealtimeClient(push)}
      />
    )

    await user.click(await screen.findByRole("button", {name: "Private message actions for Zed"}))
    await user.click(screen.getByRole("menuitem", {name: "Close"}))

    expect(await screen.findByRole("heading", {name: "akash"})).toBeInTheDocument()
    expect(screen.queryByText("Zed")).not.toBeInTheDocument()
    expect(apiClient.bootstrap).toHaveBeenCalledTimes(2)
    expect(push).toHaveBeenCalledWith("direct_message:close", {
      buffer_id: "direct:9",
      expected_revision: 1,
    })
  })

  test("renders IRC join events as channel meta messages", async () => {
    mockBootstrapFetch()
    let realtimeHandlers
    const client = fakeRealtimeClient(vi.fn())

    render(
      <TopicsClubApp
        currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}}
        developerOauth={true}
        realtimeClientFactory={({handlers}) => {
          realtimeHandlers = handlers
          return client
        }}
      />
    )

    expect(await screen.findByRole("heading", {name: "#testing"})).toBeInTheDocument()

    realtimeHandlers.onBufferMessage(canonicalMessage({
      buffer_id: "channel:7",
      id: 206,
      nick: "dev23",
      body: "dev23 joined #elixir.",
      kind: "join",
      occurred_at: "2026-05-13T10:05:00Z",
    }))

    expect(await screen.findByText("dev23 joined #elixir.")).toBeInTheDocument()
    expect(screen.queryByText("dev23:")).not.toBeInTheDocument()
  })

  test("rejects canonical-looking realtime events owned by another server", async () => {
    mockBootstrapFetch({channelMentionCount: 3, channelUnreadCount: 4})
    const client = fakeRealtimeClient(vi.fn().mockResolvedValue({ok: true}))
    let realtimeHandlers

    render(
      <TopicsClubApp
        currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}}
        developerOauth={true}
        realtimeClientFactory={({handlers}) => {
          realtimeHandlers = handlers
          return client
        }}
      />
    )

    expect(await screen.findByRole("heading", {name: "#testing"})).toBeInTheDocument()

    act(() => {
      realtimeHandlers.onBufferMessage(canonicalMessage({
        id: 207,
        buffer_id: "channel:7",
        server_connection_id: 99,
        nick: "intruder",
        body: "wrong owner message",
      }))
      realtimeHandlers.onPresenceSync(canonicalPresenceSync(
        [{nick: "intruder", nick_key: "intruder", role: "user", status: "online"}],
        {server_connection_id: 99}
      ))
      realtimeHandlers.onBufferRead(canonicalBufferRead("channel:7", {server_connection_id: 99}))
      realtimeHandlers.onBufferLeft(canonicalBufferLeft("channel:7", {server_connection_id: 99}))
    })

    expect(screen.queryByText("wrong owner message")).not.toBeInTheDocument()
    expect(screen.queryByText("intruder")).not.toBeInTheDocument()
    expect(screen.getByRole("heading", {name: "#testing"})).toBeInTheDocument()
    expect(screen.getByLabelText("4 unread messages in #testing")).toBeInTheDocument()
  })

  test("reconciles messages newer than the bootstrap cursor", async () => {
    mockBootstrapFetch({
      afterMessages: [
        {
          id: 100,
          buffer_id: "channel:7",
          nick: "mira",
          body: "missed during bootstrap",
          kind: "message",
          mentioned: false,
          occurred_at: "2026-05-13T10:01:00Z",
          occurredAt: "invalid",
          clientMessageId: "wire-client-id",
          pending: true,
          failed: true,
        },
      ],
    })

    render(<TopicsClubApp currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}} developerOauth={true} />)

    expect(await screen.findByText("loaded from bootstrap")).toBeInTheDocument()
    expect(await screen.findByText("missed during bootstrap")).toBeInTheDocument()
    expect(screen.queryByRole("button", {name: "Retry"})).not.toBeInTheDocument()
    expect(screen.getByText("missed during bootstrap").closest("div")?.querySelector("time")).toHaveAttribute("datetime", "2026-05-13T10:01:00Z")
    expect(globalThis.fetch).toHaveBeenCalledWith(
      "/api/buffer_messages?limit=50&buffer_id=channel%3A7",
      expect.objectContaining({credentials: "same-origin"})
    )
  })

  test("joins a requested backend topic by its id", async () => {
    mockResolvedLocalTopicFetch()
    window.history.pushState({}, "", "/chat?topic=101")

    render(<TopicsClubApp currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}} developerOauth={true} />)

    expect(await screen.findByRole("heading", {name: "#elixir"})).toBeInTheDocument()
    await waitFor(() =>
      expect(globalThis.fetch).toHaveBeenCalledWith(
        "/api/topics/101/join",
        expect.objectContaining({method: "POST", credentials: "same-origin"})
      )
    )

    window.history.pushState({}, "", "/")
  })

  test("does not render prototype chat when bootstrap is unavailable", async () => {
    vi.spyOn(globalThis, "fetch").mockImplementation(async (path) => {
      if (path === "/api/bootstrap") throw new Error("offline")

      return {
        ok: true,
        json: async () => ({topics: topicFixtures}),
      }
    })

    render(<TopicsClubApp currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}} developerOauth={true} />)

    expect(screen.getByRole("heading", {name: "Chat"})).toBeInTheDocument()
    expect(screen.queryByText(/placeholder chat until the IRC backend is wired/i)).not.toBeInTheDocument()
    expect(screen.queryByText("Phoenix, OTP, releases, and production Elixir help.")).not.toBeInTheDocument()
  })

  test("does not open realtime for a schema-invalid initial bootstrap", async () => {
    const seedClient = directMessageApiClient()
    const initial = await seedClient.bootstrap()
    const invalid = {
      ...initial,
      buffers: initial.buffers.map((buffer) =>
        buffer.buffer_type === "channel" ? {...buffer, subtitle: {}} : buffer
      ),
    }
    const apiClient = {
      ...seedClient,
      bootstrap: vi.fn().mockResolvedValue(invalid),
    }
    const realtimeClientFactory = vi.fn(() => fakeRealtimeClient(vi.fn()))

    render(
      <TopicsClubApp
        apiClient={apiClient as any}
        currentUser={{id: 1, email: "mira@example.com"}}
        developerOauth={true}
        realtimeClientFactory={realtimeClientFactory}
      />
    )

    await act(async () => {
      await apiClient.bootstrap.mock.results[0]?.value
    })

    expect(realtimeClientFactory).not.toHaveBeenCalled()
    expect(screen.queryByText("Zed")).not.toBeInTheDocument()
  })

  test("sends channel messages through the realtime client and replaces pending message", async () => {
    const user = userEvent.setup()
    mockBootstrapFetch()
    const push = vi.fn().mockResolvedValue({
      client_message_id: "client-reply",
      message: canonicalMessage({
        id: 100,
        buffer_id: "channel:7",
        nick: "mira",
        body: "sent through socket",
        kind: "message",
        mentioned: false,
        occurred_at: "2026-05-13T10:01:00Z",
        occurredAt: "invalid",
        clientMessageId: "wire-client-id",
        pending: true,
        failed: true,
      }),
    })
    const client = fakeRealtimeClient(push)
    let realtimeHandlers

    render(
      <TopicsClubApp
        currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}}
        developerOauth={true}
        realtimeClientFactory={({handlers}) => {
          realtimeHandlers = handlers
          return client
        }}
      />
    )

    expect(await screen.findByRole("heading", {name: "#testing"})).toBeInTheDocument()
    realtimeHandlers.onJoinOk()

    await user.type(screen.getByLabelText("Message composer"), "sent through socket")
    await user.click(screen.getByRole("button", {name: "Send"}))

    expect(push).toHaveBeenCalledWith(
      "message:send",
      expect.objectContaining({
        buffer_id: "channel:7",
        body: "sent through socket",
        client_message_id: expect.stringMatching(/^client-/),
      })
    )
    expect(await screen.findByText("sent through socket")).toBeInTheDocument()
    expect(screen.queryByText("sending")).not.toBeInTheDocument()
    expect(screen.queryByRole("button", {name: "Retry"})).not.toBeInTheDocument()
    expect(screen.getByText("sent through socket").closest("div")?.querySelector("time")).toHaveAttribute("datetime", "2026-05-13T10:01:00Z")
  })

  test("uses the IRC nickname for the optimistic outgoing message", async () => {
    const user = userEvent.setup()
    mockBootstrapFetch({connectionNickname: "dev2dev"})
    let resolveSend
    const sendReply = new Promise((resolve) => {
      resolveSend = resolve
    })
    const client = fakeRealtimeClient(vi.fn(() => sendReply))
    let realtimeHandlers

    render(
      <TopicsClubApp
        currentUser={{id: 1, email: "dev@example.com"}}
        developerOauth={true}
        realtimeClientFactory={({handlers}) => {
          realtimeHandlers = handlers
          return client
        }}
      />
    )

    expect(await screen.findByRole("heading", {name: "#testing"})).toBeInTheDocument()
    realtimeHandlers.onJoinOk()
    await user.type(screen.getByLabelText("Message composer"), "nickname should not flicker")
    await user.click(screen.getByRole("button", {name: "Send"}))

    expect(screen.getByRole("button", {name: "Mention dev2dev"})).toBeInTheDocument()
    expect(screen.queryByRole("button", {name: "Mention dev"})).not.toBeInTheDocument()

    await act(async () => resolveSend({
      message: canonicalMessage({
        id: 303,
        buffer_id: "channel:7",
        nick: "dev2dev",
        body: "nickname should not flicker",
        occurred_at: "2026-08-26T10:00:00Z",
      }),
    }))
  })

  test("uses the current IRC nickname when retrying a failed optimistic message", async () => {
    const user = userEvent.setup()
    mockBootstrapFetch({connectionNickname: "dev2dev"})
    let resolveRetry
    const retryReply = new Promise((resolve) => {
      resolveRetry = resolve
    })
    const push = vi.fn().mockRejectedValueOnce({reason: "not_connected"}).mockReturnValueOnce(retryReply)
    const client = fakeRealtimeClient(push)
    let realtimeHandlers

    render(
      <TopicsClubApp
        currentUser={{id: 1, email: "dev@example.com"}}
        developerOauth={true}
        realtimeClientFactory={({handlers}) => {
          realtimeHandlers = handlers
          return client
        }}
      />
    )

    expect(await screen.findByRole("heading", {name: "#testing"})).toBeInTheDocument()
    realtimeHandlers.onJoinOk()
    await user.type(screen.getByLabelText("Message composer"), "retry after nick change")
    await user.click(screen.getByRole("button", {name: "Send"}))
    expect(await screen.findByRole("button", {name: "Retry"})).toBeInTheDocument()

    act(() => realtimeHandlers.onServerStatus(canonicalServerStatus("connected", {nickname: "dev3dev"})))
    await user.click(screen.getByRole("button", {name: "Retry"}))

    expect(screen.getByRole("button", {name: "Mention dev3dev"})).toBeInTheDocument()
    expect(screen.queryByRole("button", {name: "Mention dev2dev"})).not.toBeInTheDocument()

    await act(async () => resolveRetry({
      message: canonicalMessage({
        id: 304,
        buffer_id: "channel:7",
        nick: "dev3dev",
        body: "retry after nick change",
        occurred_at: "2026-08-26T10:01:00Z",
      }),
    }))
  })

  test("rejects a sent-message reply from a different server connection", async () => {
    const user = userEvent.setup()
    mockBootstrapFetch()
    const push = vi.fn().mockResolvedValue({
      message: canonicalMessage({
        id: 100,
        buffer_id: "channel:7",
        server_connection_id: 999,
        nick: "mira",
        body: "wrong server",
        kind: "message",
        mentioned: false,
        occurred_at: "2026-05-13T10:01:00Z",
      }),
    })
    const client = fakeRealtimeClient(push)
    let realtimeHandlers

    render(
      <TopicsClubApp
        currentUser={{id: 1, email: "mira@example.com"}}
        developerOauth={true}
        realtimeClientFactory={({handlers}) => {
          realtimeHandlers = handlers
          return client
        }}
      />
    )

    expect(await screen.findByRole("heading", {name: "#testing"})).toBeInTheDocument()
    realtimeHandlers.onJoinOk()
    await user.type(screen.getByLabelText("Message composer"), "wrong server")
    await user.click(screen.getByRole("button", {name: "Send"}))

    expect(await screen.findByRole("button", {name: "Retry"})).toBeInTheDocument()
  })

  test("marks realtime channel send failures in the timeline", async () => {
    const user = userEvent.setup()
    mockBootstrapFetch()
    const client = fakeRealtimeClient(vi.fn().mockRejectedValue({reason: "not_connected"}))
    let realtimeHandlers

    render(
      <TopicsClubApp
        currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}}
        developerOauth={true}
        realtimeClientFactory={({handlers}) => {
          realtimeHandlers = handlers
          return client
        }}
      />
    )

    expect(await screen.findByRole("heading", {name: "#testing"})).toBeInTheDocument()
    realtimeHandlers.onJoinOk()

    await user.type(screen.getByLabelText("Message composer"), "will fail")
    await user.click(screen.getByRole("button", {name: "Send"}))

    expect(await screen.findByRole("button", {name: "Retry"})).toBeInTheDocument()
  })

  test("marks realtime channel send timeouts in the timeline", async () => {
    const user = userEvent.setup()
    mockBootstrapFetch()
    const client = fakeRealtimeClient(vi.fn().mockRejectedValue({reason: "timeout"}))
    let realtimeHandlers

    render(
      <TopicsClubApp
        currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}}
        developerOauth={true}
        realtimeClientFactory={({handlers}) => {
          realtimeHandlers = handlers
          return client
        }}
      />
    )

    expect(await screen.findByRole("heading", {name: "#testing"})).toBeInTheDocument()
    realtimeHandlers.onJoinOk()

    await user.type(screen.getByLabelText("Message composer"), "will timeout")
    await user.click(screen.getByRole("button", {name: "Send"}))

    expect(await screen.findByRole("button", {name: "Retry"})).toBeInTheDocument()
    expect(screen.getByText("will timeout")).toBeInTheDocument()
  })

  test("retries failed realtime channel messages", async () => {
    const user = userEvent.setup()
    mockBootstrapFetch()
    const push = vi
      .fn()
      .mockRejectedValueOnce({reason: "not_connected"})
      .mockResolvedValueOnce({
        message: canonicalMessage({
          id: 101,
          buffer_id: "channel:7",
          nick: "mira",
          body: "try again",
          kind: "message",
          mentioned: false,
          occurred_at: "2026-05-13T10:02:00Z",
        }),
      })
    const client = fakeRealtimeClient(push)
    let realtimeHandlers

    render(
      <TopicsClubApp
        currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}}
        developerOauth={true}
        realtimeClientFactory={({handlers}) => {
          realtimeHandlers = handlers
          return client
        }}
      />
    )

    expect(await screen.findByRole("heading", {name: "#testing"})).toBeInTheDocument()
    realtimeHandlers.onJoinOk()

    await user.type(screen.getByLabelText("Message composer"), "try again")
    await user.click(screen.getByRole("button", {name: "Send"}))
    await user.click(await screen.findByRole("button", {name: "Retry"}))

    await waitFor(() => expect(push).toHaveBeenCalledTimes(2))
    expect(push).toHaveBeenLastCalledWith(
      "message:send",
      expect.objectContaining({
        buffer_id: "channel:7",
        body: "try again",
        client_message_id: expect.stringMatching(/^client-/),
      })
    )
    expect(await screen.findByText("try again")).toBeInTheDocument()
    expect(screen.queryByRole("button", {name: "Retry"})).not.toBeInTheDocument()
  })

  test("keeps channel drafts unsent while the realtime socket is offline", async () => {
    const user = userEvent.setup()
    mockBootstrapFetch()
    const push = vi.fn()
    const client = fakeRealtimeClient(push)

    render(
      <TopicsClubApp
        currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}}
        developerOauth={true}
        realtimeClientFactory={() => client}
      />
    )

    expect(await screen.findByRole("heading", {name: "#testing"})).toBeInTheDocument()

    const composer = screen.getByLabelText("Message composer")
    await user.type(composer, "still drafting")

    expect(screen.getByRole("button", {name: "Send"})).toBeDisabled()
    expect(push).not.toHaveBeenCalled()
    expect(composer).toHaveValue("still drafting")
  })

  test("keeps channel drafts unsent while the IRC server is still connecting", async () => {
    const user = userEvent.setup()
    mockBootstrapFetch({connectionStatus: "connected"})
    const push = vi.fn()
    const client = fakeRealtimeClient(push)
    let realtimeHandlers

    render(
      <TopicsClubApp
        currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}}
        developerOauth={true}
        realtimeClientFactory={({handlers}) => {
          realtimeHandlers = handlers
          return client
        }}
      />
    )

    expect(await screen.findByRole("heading", {name: "#testing"})).toBeInTheDocument()
    realtimeHandlers.onJoinOk()

    const composer = screen.getByLabelText("Message composer")
    await user.type(composer, "wait for irc")
    act(() => realtimeHandlers.onServerStatus(canonicalServerStatus("connecting")))
    await user.type(composer, " ignored")

    expect(screen.getByRole("button", {name: "Send"})).toBeDisabled()
    expect(push).not.toHaveBeenCalled()
    expect(composer).toHaveValue("wait for irc")
    expect(composer).toHaveAttribute("readonly")
    expect(screen.getByRole("button", {name: "View issue"})).toBeInTheDocument()
    expect(screen.getByText("Reconnecting...")).toBeInTheDocument()
  })

  test("reconciles missed messages in order when an IRC server reconnects", async () => {
    let realtimeHandlers
    const client = fakeRealtimeClient(vi.fn())
    mockBootstrapFetch({
      connectionStatus: "connecting",
      afterMessages: [
        {
          id: 101,
          buffer_id: "channel:7",
          nick: "akash",
          body: "second missed",
          kind: "message",
          mentioned: false,
          occurred_at: "2026-05-13T10:02:00Z",
        },
        {
          id: 100,
          buffer_id: "channel:7",
          nick: "mira",
          body: "first missed",
          kind: "message",
          mentioned: false,
          occurred_at: "2026-05-13T10:01:00Z",
        },
      ],
    })

    render(
      <TopicsClubApp
        currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}}
        developerOauth={true}
        realtimeClientFactory={({handlers}) => {
          realtimeHandlers = handlers
          return client
        }}
      />
    )

    expect(await screen.findByText("loaded from bootstrap")).toBeInTheDocument()
    realtimeHandlers.onServerStatus(canonicalServerStatus("connected"))

    expect(await screen.findByText("first missed")).toBeInTheDocument()
    expect(await screen.findByText("second missed")).toBeInTheDocument()
    expect(globalThis.fetch).toHaveBeenCalledWith(
      "/api/buffer_messages?limit=50&buffer_id=channel%3A7",
      expect.objectContaining({credentials: "same-origin"})
    )

    const bootstrapMessage = screen.getByText("loaded from bootstrap")
    const firstMissed = screen.getByText("first missed")
    const secondMissed = screen.getByText("second missed")
    expect(Boolean(bootstrapMessage.compareDocumentPosition(firstMissed) & Node.DOCUMENT_POSITION_FOLLOWING)).toBe(true)
    expect(Boolean(firstMissed.compareDocumentPosition(secondMissed) & Node.DOCUMENT_POSITION_FOLLOWING)).toBe(true)
  })

  test("reconciles missed messages when the browser realtime socket reopens", async () => {
    let realtimeHandlers
    const client = fakeRealtimeClient(vi.fn())
    mockBootstrapFetch({
      afterMessages: [
        {
          id: 100,
          buffer_id: "channel:7",
          nick: "akash",
          body: "missed while socket was away",
          kind: "message",
          mentioned: false,
          occurred_at: "2026-05-13T10:01:00Z",
        },
      ],
    })

    render(
      <TopicsClubApp
        currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}}
        developerOauth={true}
        realtimeClientFactory={({handlers}) => {
          realtimeHandlers = handlers
          return client
        }}
      />
    )

    expect(await screen.findByText("loaded from bootstrap")).toBeInTheDocument()
    realtimeHandlers.onJoinOk()

    expect(await screen.findByText("missed while socket was away")).toBeInTheDocument()
    expect(globalThis.fetch).toHaveBeenCalledWith(
      "/api/buffer_messages?limit=50&buffer_id=channel%3A7",
      expect.objectContaining({credentials: "same-origin"})
    )
  })

  test("repairs a missed in-place command status update when the socket reopens", async () => {
    let realtimeHandlers
    const client = fakeRealtimeClient(vi.fn())
    const sentCommand = {
      id: 99,
      buffer_id: "channel:7",
      nick: "mira",
      body: "WHOIS mira",
      kind: "command",
      metadata: {command_id: "whois-reconnect-1", command_status: "sent"},
      occurred_at: "2026-05-13T10:00:00Z",
    }
    const completedCommand = {
      ...sentCommand,
      metadata: {command_id: "whois-reconnect-1", command_status: "completed"},
    }

    mockBootstrapFetch({
      bootstrapChannelMessages: [sentCommand],
      bufferMessageResponses: [[], [], [], [completedCommand]],
    })

    render(
      <TopicsClubApp
        currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}}
        developerOauth={true}
        realtimeClientFactory={({handlers}) => {
          realtimeHandlers = handlers
          return client
        }}
      />
    )

    const commandRow = (await screen.findByText("WHOIS mira")).closest("[data-command-status]")
    expect(commandRow).toHaveAttribute("data-command-status", "sent")

    await waitFor(() => {
      const requests = globalThis.fetch.mock.calls.filter(([path]) => String(path).startsWith("/api/buffer_messages"))
      expect(requests).toHaveLength(3)
    })

    realtimeHandlers.onJoinOk()

    await waitFor(() => expect(commandRow).toHaveAttribute("data-command-status", "completed"))
    expect(screen.getAllByText("WHOIS mira")).toHaveLength(1)
  })

  test("chunks command status repair requests", async () => {
    let realtimeHandlers
    const sentCommands = Array.from({length: 51}, (_, index) => ({
      id: 200 + index,
      buffer_id: "channel:7",
      nick: "mira",
      body: `WHOIS user${index}`,
      kind: "command",
      metadata: {command_id: `whois-${index}`, command_status: "sent"},
      occurred_at: `2026-05-13T10:00:${String(index).padStart(2, "0")}Z`,
    }))

    mockBootstrapFetch({bootstrapChannelMessages: sentCommands, bufferMessageResponses: [[]]})

    render(
      <TopicsClubApp
        currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}}
        developerOauth={true}
        realtimeClientFactory={({handlers}) => {
          realtimeHandlers = handlers
          return fakeRealtimeClient(vi.fn())
        }}
      />
    )

    expect(await screen.findByText("WHOIS user0")).toBeInTheDocument()
    realtimeHandlers.onJoinOk()

    await waitFor(() => {
      const repairPaths = globalThis.fetch.mock.calls
        .map(([path]) => String(path))
        .filter((path) => path.includes("command_ids="))

      expect(repairPaths).toHaveLength(2)
      expect(
        repairPaths.map((path) => new URL(path, "http://localhost").searchParams.get("command_ids").split(",").length)
      ).toEqual([50, 1])
    })
  })

  test("does not let a stale tail response regress a realtime command completion", async () => {
    let realtimeHandlers
    let resolveTail
    const staleTail = new Promise((resolve) => {
      resolveTail = resolve
    })
    const sentCommand = {
      id: 99,
      buffer_id: "channel:7",
      nick: "mira",
      body: "WHOIS mira",
      kind: "command",
      metadata: {command_id: "whois-race-1", command_status: "sent"},
      occurred_at: "2026-05-13T10:00:00Z",
    }

    mockBootstrapFetch({
      bootstrapChannelMessages: [sentCommand],
      bufferMessageResponses: [staleTail],
    })

    render(
      <TopicsClubApp
        currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}}
        developerOauth={true}
        realtimeClientFactory={({handlers}) => {
          realtimeHandlers = handlers
          return fakeRealtimeClient(vi.fn())
        }}
      />
    )

    const commandRow = (await screen.findByText("WHOIS mira")).closest("[data-command-status]")
    expect(commandRow).toHaveAttribute("data-command-status", "sent")

    realtimeHandlers.onBufferMessage(canonicalMessage({
      ...sentCommand,
      metadata: {command_id: "whois-race-1", command_status: "completed"},
    }))

    await waitFor(() => expect(commandRow).toHaveAttribute("data-command-status", "completed"))
    resolveTail([sentCommand])
    await waitFor(() => expect(commandRow).toHaveAttribute("data-command-status", "completed"))
  })

  test("shows degraded connection health when the realtime join fails", async () => {
    mockBootstrapFetch()
    let realtimeHandlers
    const client = fakeRealtimeClient(vi.fn())

    render(
      <TopicsClubApp
        currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}}
        developerOauth={true}
        realtimeClientFactory={({handlers}) => {
          realtimeHandlers = handlers
          return client
        }}
      />
    )

    expect(await screen.findByRole("heading", {name: "#testing"})).toBeInTheDocument()

    realtimeHandlers.onJoinError({reason: "unauthorized"})

    await waitFor(() => expect(screen.getByLabelText("Connection degraded")).toBeInTheDocument())
  })

  test("updates connection health from socket lifecycle callbacks", async () => {
    mockBootstrapFetch()
    let realtimeHandlers
    const client = fakeRealtimeClient(vi.fn())

    render(
      <TopicsClubApp
        currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}}
        developerOauth={true}
        realtimeClientFactory={({handlers}) => {
          realtimeHandlers = handlers
          return client
        }}
      />
    )

    expect(await screen.findByRole("heading", {name: "#testing"})).toBeInTheDocument()

    realtimeHandlers.onJoinOk()
    await waitFor(() => expect(screen.getByLabelText("Connection connected")).toBeInTheDocument())

    realtimeHandlers.onClose()
    await waitFor(() => expect(screen.getByLabelText("Connection reconnecting")).toBeInTheDocument())

    realtimeHandlers.onError()
    await waitFor(() => expect(screen.getByLabelText("Connection degraded")).toBeInTheDocument())
  })

  test("offers a retry action when the realtime socket is degraded", async () => {
    mockBootstrapFetch()
    let realtimeHandlers
    const client = fakeRealtimeClient(vi.fn())
    const user = userEvent.setup()

    render(
      <TopicsClubApp
        currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}}
        developerOauth={true}
        realtimeClientFactory={({handlers}) => {
          realtimeHandlers = handlers
          return client
        }}
      />
    )

    expect(await screen.findByRole("heading", {name: "#testing"})).toBeInTheDocument()

    realtimeHandlers.onError()
    await user.click(await screen.findByRole("button", {name: "Retry realtime connection"}))

    expect(client.reconnect).toHaveBeenCalledOnce()
    expect(screen.getByLabelText("Connection reconnecting")).toBeInTheDocument()
  })

  test("updates the user sidebar from presence sync events", async () => {
    mockBootstrapFetch()
    let realtimeHandlers
    const client = fakeRealtimeClient(vi.fn())

    render(
      <TopicsClubApp
        currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}}
        developerOauth={true}
        realtimeClientFactory={({handlers}) => {
          realtimeHandlers = handlers
          return client
        }}
      />
    )

    expect(await screen.findByRole("heading", {name: "#testing"})).toBeInTheDocument()

    realtimeHandlers.onPresenceSync(
      canonicalPresenceSync([
        {nick: "mira", nick_key: "mira", role: "op", status: "online"},
        {nick: "akash", nick_key: "akash", role: "user", status: "online"},
      ])
    )

    const people = screen.getByRole("complementary", {name: "People here"})
    await waitFor(() => expect(within(people).getByText("akash")).toBeInTheDocument())
    expect(within(people).getByText("mira")).toBeInTheDocument()
  })

  test("applies incremental presence diff events to the user sidebar", async () => {
    mockBootstrapFetch()
    let realtimeHandlers
    const client = fakeRealtimeClient(vi.fn())

    render(
      <TopicsClubApp
        currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}}
        developerOauth={true}
        realtimeClientFactory={({handlers}) => {
          realtimeHandlers = handlers
          return client
        }}
      />
    )

    expect(await screen.findByRole("heading", {name: "#testing"})).toBeInTheDocument()

    realtimeHandlers.onPresenceSync(
      canonicalPresenceSync([{nick: "mira", nick_key: "mira", role: "op", status: "online"}])
    )

    realtimeHandlers.onPresenceSync(
      canonicalPresenceSync([{nick: "malformed", role: "user", status: "online"}])
    )
    realtimeHandlers.onPresenceDiff(canonicalPresenceDiff({action: "part", nick: "mira"}))

    realtimeHandlers.onPresenceDiff(
      canonicalPresenceDiff({
        action: "join",
        user: {nick: "akash", nick_key: "akash", role: "user", status: "online"},
      })
    )

    const people = screen.getByRole("complementary", {name: "People here"})
    await waitFor(() => expect(within(people).getByText("akash")).toBeInTheDocument())

    realtimeHandlers.onPresenceDiff(
      canonicalPresenceDiff({action: "away", nick: "akash", nick_key: "akash", status: "away"})
    )
    await waitFor(() => expect(within(people).getByText("Away")).toBeInTheDocument())
    expect(within(people).getByText("akash")).toBeInTheDocument()

    realtimeHandlers.onPresenceDiff(
      canonicalPresenceDiff({action: "away", nick: "akash", nick_key: "akash", status: "online"})
    )
    await waitFor(() => expect(within(people).queryByText("Away")).not.toBeInTheDocument())

    realtimeHandlers.onPresenceDiff(
      canonicalPresenceDiff({action: "role", nick: "akash", nick_key: "akash", role: "op"})
    )
    await waitFor(() => expect(within(people).getByText("Mods")).toBeInTheDocument())
    await waitFor(() => expect(within(people).getAllByText("mod")).toHaveLength(2))
    expect(within(people).getByText("akash")).toBeInTheDocument()

    realtimeHandlers.onPresenceDiff(
      canonicalPresenceDiff({action: "role", nick: "akash", nick_key: "akash", role: "user"})
    )
    await waitFor(() => expect(within(people).getAllByText("mod")).toHaveLength(1))

    realtimeHandlers.onPresenceDiff(
      canonicalPresenceDiff({
        action: "nick",
        old_nick: "akash",
        old_nick_key: "akash",
        new_nick: "ak",
        new_nick_key: "ak",
      })
    )
    await waitFor(() => expect(within(people).getByText("ak")).toBeInTheDocument())

    realtimeHandlers.onPresenceDiff(
      canonicalPresenceDiff({action: "part", nick: "ak", nick_key: "ak"})
    )
    await waitFor(() => expect(within(people).queryByText("ak")).not.toBeInTheDocument())
  })

  test("removes a channel buffer after a realtime leave event", async () => {
    mockBootstrapFetch()
    let realtimeHandlers
    const client = fakeRealtimeClient(vi.fn())

    render(
      <TopicsClubApp
        currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}}
        developerOauth={true}
        realtimeClientFactory={({handlers}) => {
          realtimeHandlers = handlers
          return client
        }}
      />
    )

    expect(await screen.findByRole("heading", {name: "#testing"})).toBeInTheDocument()

    realtimeHandlers.onBufferLeft(canonicalBufferLeft("channel:7"))

    expect(await screen.findByRole("heading", {name: "127.0.0.1", level: 2})).toBeInTheDocument()
    expect(screen.queryByRole("button", {name: /#testing/})).not.toBeInTheDocument()
    expect(screen.queryByRole("complementary", {name: "People here"})).not.toBeInTheDocument()
  })

  test("removes a server after a realtime server buffer leave event", async () => {
    mockBootstrapFetch()
    let realtimeHandlers
    const client = fakeRealtimeClient(vi.fn())

    render(
      <TopicsClubApp
        currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}}
        developerOauth={true}
        realtimeClientFactory={({handlers}) => {
          realtimeHandlers = handlers
          return client
        }}
      />
    )

    expect(await screen.findByRole("heading", {name: "#testing"})).toBeInTheDocument()

    realtimeHandlers.onBufferLeft(canonicalBufferLeft("server:42"))

    expect(await screen.findByRole("heading", {name: "Find your next conversation."})).toBeInTheDocument()
    expect(screen.queryByRole("button", {name: /#testing/})).not.toBeInTheDocument()
    expect(screen.queryByRole("button", {name: /^local$/i})).not.toBeInTheDocument()
  })

  test("adds a channel buffer after a realtime joined event", async () => {
    const user = userEvent.setup()
    mockBootstrapFetch()
    let realtimeHandlers
    const client = fakeRealtimeClient(vi.fn())

    render(
      <TopicsClubApp
        currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}}
        developerOauth={true}
        realtimeClientFactory={({handlers}) => {
          realtimeHandlers = handlers
          return client
        }}
      />
    )

    expect(await screen.findByRole("heading", {name: "#testing"})).toBeInTheDocument()

    realtimeHandlers.onBufferJoined(canonicalBufferJoined({
      connection: {
        id: 42,
        name: "local",
        host: "127.0.0.1",
        port: 6669,
        use_tls: false,
        nickname: "mira",
        status: "connected",
        mention_notifications_enabled: true,
        notification_preference_revision: 0,
      },
      buffer: {
        buffer_id: "channel:8",
        buffer_type: "channel",
        server_connection_id: 42,
        channel_membership_id: 8,
        title: "#phoenix",
        subtitle: "on 127.0.0.1",
        status: "connected",
        unread_count: 0,
        mention_count: 0,
        mention_notifications_enabled: true,
        notification_preference_revision: 0,
      },
    }))

    await user.click(await screen.findByRole("button", {name: /^#phoenix$/i}))

    expect(screen.getByRole("heading", {name: "#phoenix"})).toBeInTheDocument()
  })

  test("renders realtime server buffer messages", async () => {
    const user = userEvent.setup()
    mockBootstrapFetch()
    let realtimeHandlers
    const client = fakeRealtimeClient(vi.fn())

    render(
      <TopicsClubApp
        currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}}
        developerOauth={true}
        realtimeClientFactory={({handlers}) => {
          realtimeHandlers = handlers
          return client
        }}
      />
    )

    expect(await screen.findByRole("heading", {name: "#testing"})).toBeInTheDocument()
    await user.click(screen.getByRole("button", {name: "local"}))

    realtimeHandlers.onBufferMessage(canonicalMessage({
      buffer_id: "server:42",
      id: 204,
      nick: "127.0.0.1",
      body: "MOTD starts here",
      kind: "notice",
      occurred_at: "2026-05-13T10:03:00Z",
    }))

    expect(await screen.findByText("MOTD starts here")).toBeInTheDocument()
  })

  test("shows a new message affordance while reading older chat", async () => {
    const user = userEvent.setup()
    mockBootstrapFetch()
    let realtimeHandlers
    const client = fakeRealtimeClient(vi.fn())

    render(
      <TopicsClubApp
        currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}}
        developerOauth={true}
        realtimeClientFactory={({handlers}) => {
          realtimeHandlers = handlers
          return client
        }}
      />
    )

    expect(await screen.findByRole("heading", {name: "#testing"})).toBeInTheDocument()

    const scrollback = document.getElementById("chat-scrollback")
    Object.defineProperty(scrollback, "scrollHeight", {value: 1000, configurable: true})
    Object.defineProperty(scrollback, "clientHeight", {value: 500, configurable: true})
    Object.defineProperty(scrollback, "scrollTop", {value: 100, writable: true, configurable: true})
    fireEvent.scroll(scrollback)

    realtimeHandlers.onBufferMessage(canonicalMessage({
      buffer_id: "channel:7",
      id: 205,
      nick: "akash",
      body: "new while reading",
      kind: "message",
      occurred_at: "2026-05-13T10:04:00Z",
    }))

    const jump = await screen.findByRole("button", {name: "1 new message"})
    await user.click(jump)

    expect(screen.queryByRole("button", {name: "1 new message"})).not.toBeInTheDocument()
  })

  test("caps large user groups and expands them on request", async () => {
    const user = userEvent.setup()
    mockBootstrapFetch()
    let realtimeHandlers
    const client = fakeRealtimeClient(vi.fn())
    const manyUsers = Array.from({length: 12}, (_, index) => ({
      nick: `user${index + 1}`,
      nick_key: `user${index + 1}`,
      role: "user",
      status: "online",
    }))

    render(
      <TopicsClubApp
        currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}}
        developerOauth={true}
        realtimeClientFactory={({handlers}) => {
          realtimeHandlers = handlers
          return client
        }}
      />
    )

    expect(await screen.findByRole("heading", {name: "#testing"})).toBeInTheDocument()

    realtimeHandlers.onPresenceSync(canonicalPresenceSync(manyUsers))

    const people = screen.getByRole("complementary", {name: "People here"})
    await waitFor(() => expect(within(people).getByText("user10")).toBeInTheDocument())
    expect(within(people).queryByText("user11")).not.toBeInTheDocument()

    await user.click(within(people).getByRole("button", {name: "+2 more"}))

    expect(within(people).getByText("user12")).toBeInTheDocument()
  })

  test("requests browser notification permission from the bell button", async () => {
    const user = userEvent.setup()
    mockBootstrapFetch({push: {configured: true, vapid_public_key: "AQ"}})
    const requestPermission = vi.fn().mockResolvedValue("granted")
    const NotificationMock = vi.fn()
    NotificationMock.permission = "default"
    NotificationMock.requestPermission = requestPermission
    const originalNotification = window.Notification
    const originalPushManager = window.PushManager
    const originalServiceWorker = navigator.serviceWorker
    const subscription = {
      toJSON: () => ({
        endpoint: "https://push.example.test/subscription",
        expirationTime: null,
        keys: {p256dh: "p256dh", auth: "auth"},
      }),
    }
    const registration = {
      pushManager: {
        getSubscription: vi.fn().mockResolvedValue(null),
        subscribe: vi.fn().mockResolvedValue(subscription),
      },
    }

    Object.defineProperty(window, "Notification", {value: NotificationMock, configurable: true})
    Object.defineProperty(window, "PushManager", {value: vi.fn(), configurable: true})
    Object.defineProperty(navigator, "serviceWorker", {
      value: {ready: Promise.resolve(registration), addEventListener: vi.fn(), removeEventListener: vi.fn()},
      configurable: true,
    })

    try {
      render(<TopicsClubApp currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}} developerOauth={true} />)

      expect(await screen.findByRole("heading", {name: "#testing"})).toBeInTheDocument()
      expect(requestPermission).not.toHaveBeenCalled()

      await user.click(screen.getByLabelText("Set up mention notifications for #testing"))

      expect(requestPermission).toHaveBeenCalledTimes(1)
      const enabledBell = await screen.findByLabelText("Mute mention notifications for #testing")
      expect(enabledBell).toHaveClass("bg-transparent", "text-emerald-400")
      expect(enabledBell).not.toHaveClass("bg-emerald-300")
    } finally {
      if (originalNotification) {
        Object.defineProperty(window, "Notification", {value: originalNotification, configurable: true})
      } else {
        delete window.Notification
      }
      if (originalPushManager) {
        Object.defineProperty(window, "PushManager", {value: originalPushManager, configurable: true})
      } else {
        delete window.PushManager
      }
      if (originalServiceWorker) {
        Object.defineProperty(navigator, "serviceWorker", {value: originalServiceWorker, configurable: true})
      } else {
        delete navigator.serviceWorker
      }
    }
  })

  test("persists a channel mention mute when this device is subscribed", async () => {
    const user = userEvent.setup()
    mockBootstrapFetch({push: {configured: true, vapid_public_key: "AQ"}})
    const NotificationMock = vi.fn()
    NotificationMock.permission = "granted"
    NotificationMock.requestPermission = vi.fn().mockResolvedValue("granted")
    const originalNotification = window.Notification
    const originalPushManager = window.PushManager
    const originalServiceWorker = navigator.serviceWorker
    const installationStorageKey = "topics-club.notification-installation"
    const originalInstallation = localStorage.getItem(installationStorageKey)
    const subscription = {
      toJSON: () => ({
        endpoint: "https://push.example.test/subscription",
        expirationTime: null,
        keys: {p256dh: "p256dh", auth: "auth"},
      }),
    }
    const registration = {
      pushManager: {
        getSubscription: vi.fn().mockResolvedValue(subscription),
        subscribe: vi.fn(),
      },
    }

    Object.defineProperty(window, "Notification", {value: NotificationMock, configurable: true})
    Object.defineProperty(window, "PushManager", {value: vi.fn(), configurable: true})
    Object.defineProperty(navigator, "serviceWorker", {
      value: {ready: Promise.resolve(registration), addEventListener: vi.fn(), removeEventListener: vi.fn()},
      configurable: true,
    })
    localStorage.setItem(
      installationStorageKey,
      JSON.stringify({installation_id: "browser-installation", user_id: "1"})
    )

    try {
      render(<TopicsClubApp currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}} developerOauth={true} />)

      await user.click(await screen.findByLabelText("Mute mention notifications for #testing"))

      expect(await screen.findByLabelText("Enable mention notifications for #testing")).toBeInTheDocument()
      expect(globalThis.fetch).toHaveBeenCalledWith(
        "/api/channel_memberships/7/notification_preferences",
        expect.objectContaining({
          method: "PUT",
          body: JSON.stringify({mention_notifications_enabled: false}),
        })
      )
    } finally {
      if (originalNotification) {
        Object.defineProperty(window, "Notification", {value: originalNotification, configurable: true})
      } else {
        delete window.Notification
      }
      if (originalPushManager) {
        Object.defineProperty(window, "PushManager", {value: originalPushManager, configurable: true})
      } else {
        delete window.PushManager
      }
      if (originalServiceWorker) {
        Object.defineProperty(navigator, "serviceWorker", {value: originalServiceWorker, configurable: true})
      } else {
        delete navigator.serviceWorker
      }
      if (originalInstallation === null) {
        localStorage.removeItem(installationStorageKey)
      } else {
        localStorage.setItem(installationStorageKey, originalInstallation)
      }
    }
  })

  test.each([
    ["malformed", {scope: "channel", id: 7, mention_notifications_enabled: false}],
    ["mismatched", {scope: "channel", id: 8, mention_notifications_enabled: false, revision: 1}],
  ])("rolls back a channel mute after a %s successful HTTP payload", async (_kind, preference) => {
    const user = userEvent.setup()
    const restoreNotificationBrowser = installSubscribedNotificationBrowser()
    mockBootstrapFetch({
      push: {configured: true, vapid_public_key: "AQ"},
      channelPreferenceResponsePromise: Promise.resolve({
        ok: true,
        json: async () => ({preference}),
      }),
    })

    try {
      await act(async () => {
        render(
          <TopicsClubApp
            currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}}
            developerOauth={true}
          />
        )
      })

      await user.click(await screen.findByLabelText("Mute mention notifications for #testing"))

      await waitFor(() => {
        expect(screen.getByLabelText("Mute mention notifications for #testing")).toBeInTheDocument()
      })
      expect(globalThis.fetch).toHaveBeenCalledWith(
        "/api/channel_memberships/7/notification_preferences",
        expect.objectContaining({method: "PUT"})
      )
    } finally {
      restoreNotificationBrowser()
    }
  })

  test("ignores a delayed notification response older than a realtime mute", async () => {
    const user = userEvent.setup()
    let resolveChannelPreference
    const channelPreferenceResponsePromise = new Promise((resolve) => {
      resolveChannelPreference = resolve
    })
    mockBootstrapFetch({
      push: {configured: true, vapid_public_key: "AQ"},
      channelPreferenceResponsePromise,
    })

    const NotificationMock = vi.fn()
    NotificationMock.permission = "granted"
    NotificationMock.requestPermission = vi.fn().mockResolvedValue("granted")
    const originalNotification = window.Notification
    const originalPushManager = window.PushManager
    const originalServiceWorker = navigator.serviceWorker
    const installationStorageKey = "topics-club.notification-installation"
    const originalInstallation = localStorage.getItem(installationStorageKey)
    const subscription = {
      toJSON: () => ({
        endpoint: "https://push.example.test/subscription",
        expirationTime: null,
        keys: {p256dh: "p256dh", auth: "auth"},
      }),
    }
    const registration = {
      pushManager: {
        getSubscription: vi.fn().mockResolvedValue(subscription),
        subscribe: vi.fn(),
      },
    }
    const client = fakeRealtimeClient(vi.fn())
    let realtimeHandlers

    Object.defineProperty(window, "Notification", {value: NotificationMock, configurable: true})
    Object.defineProperty(window, "PushManager", {value: vi.fn(), configurable: true})
    Object.defineProperty(navigator, "serviceWorker", {
      value: {ready: Promise.resolve(registration), addEventListener: vi.fn(), removeEventListener: vi.fn()},
      configurable: true,
    })
    localStorage.setItem(
      installationStorageKey,
      JSON.stringify({installation_id: "browser-installation", user_id: "1"})
    )

    try {
      render(
        <TopicsClubApp
          currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}}
          developerOauth={true}
          realtimeClientFactory={({handlers}) => {
            realtimeHandlers = handlers
            return client
          }}
        />
      )

      await user.click(await screen.findByLabelText("Mute mention notifications for #testing"))
      expect(await screen.findByLabelText("Enable mention notifications for #testing")).toBeInTheDocument()

      act(() => {
        realtimeHandlers.onNotificationPreference({
          scope: "channel",
          id: 7,
          mention_notifications_enabled: true,
          revision: 0,
        })
      })
      expect(screen.getByLabelText("Enable mention notifications for #testing")).toBeInTheDocument()

      act(() => {
        realtimeHandlers.onNotificationPreference({
          scope: "channel",
          id: 7,
          mention_notifications_enabled: false,
          revision: 2,
        })
      })

      await act(async () => {
        resolveChannelPreference({
          ok: true,
          json: async () => ({
            preference: {
              scope: "channel",
              id: 7,
              mention_notifications_enabled: true,
              revision: 1,
            },
          }),
        })
        await channelPreferenceResponsePromise
      })

      expect(screen.getByLabelText("Enable mention notifications for #testing")).toBeInTheDocument()
    } finally {
      if (originalNotification) {
        Object.defineProperty(window, "Notification", {value: originalNotification, configurable: true})
      } else {
        delete window.Notification
      }
      if (originalPushManager) {
        Object.defineProperty(window, "PushManager", {value: originalPushManager, configurable: true})
      } else {
        delete window.PushManager
      }
      if (originalServiceWorker) {
        Object.defineProperty(navigator, "serviceWorker", {value: originalServiceWorker, configurable: true})
      } else {
        delete navigator.serviceWorker
      }
      if (originalInstallation === null) {
        localStorage.removeItem(installationStorageKey)
      } else {
        localStorage.setItem(installationStorageKey, originalInstallation)
      }
    }
  })

  test("lets signed-in users join their own server and channel", async () => {
    const user = userEvent.setup()
    mockManualJoinFetch()

    render(<TopicsClubApp currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}} developerOauth={true} />)

    await user.click(screen.getByLabelText("Join another server"))
    await user.type(screen.getByLabelText("Server"), "irc.example.net")
    await user.type(screen.getByLabelText("Auto-join channels"), "#music, ##deep")
    await user.click(screen.getByText("Advanced connection options"))
    await user.type(screen.getByLabelText("Nickname (optional)"), "mira")
    await user.type(screen.getByLabelText("Account password (SASL, optional)"), "account-secret")
    await user.type(screen.getByLabelText("Server password (optional)"), "network-secret")
    await user.click(screen.getByRole("button", {name: "Join"}))

    const nav = screen.getByRole("navigation", {name: "Joined topics"})
    expect(await within(nav).findByText("irc.example.net")).toBeInTheDocument()
    expect(within(nav).getByText("#music")).toBeInTheDocument()
    expect(within(nav).getByText("##deep")).toBeInTheDocument()
    expect(await screen.findByRole("heading", {name: "##deep"})).toBeInTheDocument()
    expect(globalThis.fetch).toHaveBeenCalledWith(
      "/api/connections",
      expect.objectContaining({
        method: "POST",
        body: JSON.stringify({
          connection: {
            name: "irc.example.net",
            host: "irc.example.net",
            port: 6669,
            use_tls: false,
            nickname: "mira",
            sasl_password: "account-secret",
            server_password: "network-secret",
          },
        }),
      })
    )
    expect(globalThis.fetch).toHaveBeenCalledWith(
      "/api/connections/90/channels",
      expect.objectContaining({method: "POST", body: JSON.stringify({channel: "##deep"})})
    )
  })

  test("opens a server buffer from the sidebar", async () => {
    const user = userEvent.setup()
    mockBootstrapFetch()

    render(<TopicsClubApp currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}} developerOauth={true} />)

    await user.click(await screen.findByRole("button", {name: "local"}))

    expect(screen.getByRole("heading", {name: "127.0.0.1", level: 2})).toBeInTheDocument()
    expect(screen.getByText("Server buffer")).toBeInTheDocument()
    expect(screen.queryByRole("complementary", {name: "People here"})).not.toBeInTheDocument()
    expect(screen.queryByRole("button", {name: "Show users"})).not.toBeInTheDocument()
  })

  test("rejects plain server-buffer text without faking a timeline message", async () => {
    const user = userEvent.setup()
    mockBootstrapFetch()
    const push = vi.fn()
    const client = fakeRealtimeClient(push)
    let realtimeHandlers

    render(
      <TopicsClubApp
        currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}}
        developerOauth={true}
        realtimeClientFactory={({handlers}) => {
          realtimeHandlers = handlers
          return client
        }}
      />
    )

    await user.click(await screen.findByRole("button", {name: "local"}))
    realtimeHandlers.onJoinOk()

    const composer = screen.getByLabelText("Message composer")
    await user.type(composer, "hello server")
    await user.click(screen.getByRole("button", {name: "Send"}))

    expect(screen.getByRole("alert")).toHaveTextContent(
      "Server buffers accept commands only. Try /msg NickServ help or /quote WHOIS nick."
    )
    expect(composer).toHaveValue("hello server")
    expect(push).not.toHaveBeenCalled()
    expect(within(document.querySelector("#server-scrollback")).queryByText("hello server")).not.toBeInTheDocument()
  })

  test("uses the channel action menu for read, copy, and leave actions", async () => {
    const user = userEvent.setup()
    mockBootstrapFetch()
    const writeText = vi.fn().mockResolvedValue(undefined)
    const originalClipboard = navigator.clipboard
    Object.defineProperty(navigator, "clipboard", {value: {writeText}, configurable: true})
    let realtimeHandlers
    const push = vi.fn((event) => {
      if (event === "channel:leave") {
        return Promise.resolve({status: "sent", buffer_id: "channel:7"})
      }

      return Promise.resolve({ok: true})
    })
    const client = fakeRealtimeClient(push)

    try {
      render(
        <TopicsClubApp
          currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}}
          developerOauth={true}
          realtimeClientFactory={({handlers}) => {
            realtimeHandlers = handlers
            return client
          }}
        />
      )

      expect(await screen.findByRole("heading", {name: "#testing"})).toBeInTheDocument()

      await user.click(screen.getByRole("button", {name: "Channel actions for #testing"}))
      await user.click(screen.getByRole("menuitem", {name: "Mark read"}))

      expect(push).toHaveBeenCalledWith("buffer:read", {buffer_id: "channel:7"})

      await user.click(screen.getByRole("button", {name: "Channel actions for #testing"}))
      await user.click(screen.getByRole("menuitem", {name: "Copy channel name"}))

      expect(writeText).toHaveBeenCalledWith("#testing")

      await user.click(screen.getByRole("button", {name: "Channel actions for #testing"}))
      await user.click(screen.getByRole("menuitem", {name: "Leave channel"}))

      expect(push).toHaveBeenCalledWith("channel:leave", {buffer_id: "channel:7"})
      expect(screen.getByRole("heading", {name: "#testing", level: 1})).toBeInTheDocument()

      realtimeHandlers.onBufferLeft(canonicalBufferLeft("channel:7"))

      expect(await screen.findByRole("heading", {name: "127.0.0.1", level: 2})).toBeInTheDocument()
      expect(screen.queryByRole("button", {name: /#testing/})).not.toBeInTheDocument()
    } finally {
      Object.defineProperty(navigator, "clipboard", {value: originalClipboard, configurable: true})
    }
  })

  test("marks the active channel read when it has unread mentions", async () => {
    mockBootstrapFetch({channelMentionCount: 3, channelUnreadCount: 4})
    const push = vi.fn(() => Promise.resolve({buffer_id: "channel:7", unread_count: 0, mention_count: 0}))
    const client = fakeRealtimeClient(push)
    let realtimeHandlers

    render(
      <TopicsClubApp
        currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}}
        developerOauth={true}
        realtimeClientFactory={({handlers}) => {
          realtimeHandlers = handlers
          return client
        }}
      />
    )

    expect(await screen.findByRole("heading", {name: "#testing"})).toBeInTheDocument()

    await waitFor(() => expect(push).toHaveBeenCalledWith("buffer:read", {buffer_id: "channel:7"}))
    act(() => realtimeHandlers.onBufferRead(canonicalBufferRead("channel:7")))
    await waitFor(() => expect(screen.queryByText("3")).not.toBeInTheDocument())
  })

  test("marks visible active channel read after receiving a realtime message", async () => {
    mockBootstrapFetch({channelMentionCount: 0, channelUnreadCount: 0})
    const push = vi.fn(() => Promise.resolve({ok: true}))
    let realtimeHandlers
    const client = fakeRealtimeClient(push)

    render(
      <TopicsClubApp
        currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}}
        developerOauth={true}
        realtimeClientFactory={({handlers}) => {
          realtimeHandlers = handlers
          return client
        }}
      />
    )

    expect(await screen.findByRole("heading", {name: "#testing"})).toBeInTheDocument()

    realtimeHandlers.onBufferMessage(canonicalMessage({
      id: 201,
      buffer_id: "channel:7",
      nick: "akash",
      body: "hello mira",
      kind: "message",
      mentioned: true,
      occurred_at: "2026-05-13T10:01:00Z",
    }))

    await waitFor(() => expect(push).toHaveBeenCalledWith("buffer:read", {buffer_id: "channel:7"}))
  })

  test("keeps a background channel mention unread until the tab becomes visible", async () => {
    const originalVisibility = Object.getOwnPropertyDescriptor(document, "visibilityState")
    let visibilityState: DocumentVisibilityState = "hidden"
    Object.defineProperty(document, "visibilityState", {
      configurable: true,
      get: () => visibilityState,
    })

    try {
      mockBootstrapFetch({channelMentionCount: 0, channelUnreadCount: 0})
      const push = vi.fn(() => Promise.resolve({ok: true}))
      let realtimeHandlers

      render(
        <TopicsClubApp
          currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}}
          developerOauth={true}
          realtimeClientFactory={({handlers}) => {
            realtimeHandlers = handlers
            return fakeRealtimeClient(push)
          }}
        />
      )

      expect(await screen.findByRole("heading", {name: "#testing"})).toBeInTheDocument()

      act(() => realtimeHandlers.onBufferMessage(canonicalMessage({
        id: 202,
        buffer_id: "channel:7",
        nick: "akash",
        body: "mira: are you there?",
        kind: "message",
        mentioned: true,
        unread_count: 1,
        mention_count: 1,
        occurred_at: "2026-05-13T10:02:00Z",
      })))

      await waitFor(() => expect(screen.getByLabelText("1 unread message in #testing")).toBeInTheDocument())
      expect(push).not.toHaveBeenCalledWith("buffer:read", {buffer_id: "channel:7"})

      visibilityState = "visible"
      act(() => document.dispatchEvent(new Event("visibilitychange")))

      await waitFor(() => expect(push).toHaveBeenCalledWith("buffer:read", {buffer_id: "channel:7"}))
    } finally {
      if (originalVisibility) {
        Object.defineProperty(document, "visibilityState", originalVisibility)
      } else {
        delete (document as Partial<Document>).visibilityState
      }
    }
  })

  test("marks an incoming message read when it arrives in the active channel", async () => {
    const user = userEvent.setup()
    const apiClient = directMessageApiClient()
    const push = vi.fn().mockResolvedValue({})
    let realtimeHandlers

    render(
      <TopicsClubApp
        apiClient={apiClient as any}
        currentUser={{id: 1, email: "mira@example.com"}}
        developerOauth={true}
        realtimeClientFactory={({handlers}) => {
          realtimeHandlers = handlers
          return fakeRealtimeClient(push)
        }}
      />
    )

    const nav = screen.getByRole("navigation", {name: "Joined topics"})
    await user.click(await within(nav).findByText("#zulu"))
    expect(await screen.findByRole("heading", {name: "#zulu"})).toBeInTheDocument()
    push.mockClear()

    act(() => realtimeHandlers.onBufferMessage(canonicalMessage({
      id: 304,
      buffer_id: "channel:4",
      server_connection_id: 1,
      channel_membership_id: 4,
      direct_message_thread_id: null,
      nick: "Zed",
      body: "message in the channel being read",
      mentioned: false,
      unread_count: 1,
      mention_count: 0,
      occurred_at: "2026-08-26T10:00:00Z",
    })))

    await waitFor(() => expect(push).toHaveBeenCalledWith("buffer:read", {buffer_id: "channel:4"}))
  })

  test("counts ordinary messages in inactive channels and clears the count when read", async () => {
    const user = userEvent.setup()
    const apiClient = directMessageApiClient()
    const push = vi.fn().mockResolvedValue({})
    let realtimeHandlers

    render(
      <TopicsClubApp
        apiClient={apiClient as any}
        currentUser={{id: 1, email: "mira@example.com"}}
        developerOauth={true}
        realtimeClientFactory={({handlers}) => {
          realtimeHandlers = handlers
          return fakeRealtimeClient(push)
        }}
      />
    )

    expect(await screen.findByRole("heading", {name: "Zed"})).toBeInTheDocument()
    await user.click(within(screen.getByRole("navigation", {name: "Joined topics"})).getByText("#alpha"))

    act(() => realtimeHandlers.onBufferMessage(canonicalMessage({
      id: 304,
      buffer_id: "channel:4",
      server_connection_id: 1,
      channel_membership_id: 4,
      direct_message_thread_id: null,
      nick: "Zed",
      body: "ordinary unread channel message",
      mentioned: false,
      unread_count: 1,
      mention_count: 0,
      occurred_at: "2026-08-26T10:00:00Z",
    })))

    expect(screen.getByLabelText("1 unread message in #zulu")).toBeInTheDocument()
    await user.click(within(screen.getByRole("navigation", {name: "Joined topics"})).getByText("#zulu"))
    await waitFor(() => expect(push).toHaveBeenCalledWith("buffer:read", {buffer_id: "channel:4"}))
    act(() => realtimeHandlers.onBufferRead(canonicalBufferRead("channel:4", {
      server_connection_id: 1,
      channel_membership_id: 4,
    })))
    expect(screen.queryByLabelText("1 unread message in #zulu")).not.toBeInTheDocument()
  })

  test("does not count command updates or repeated channel message events", async () => {
    const apiClient = directMessageApiClient()
    let realtimeHandlers

    render(
      <TopicsClubApp
        apiClient={apiClient as any}
        currentUser={{id: 1, email: "mira@example.com"}}
        developerOauth={true}
        realtimeClientFactory={({handlers}) => {
          realtimeHandlers = handlers
          return fakeRealtimeClient(vi.fn().mockResolvedValue({}))
        }}
      />
    )

    expect(await screen.findByRole("heading", {name: "Zed"})).toBeInTheDocument()
    const message = canonicalMessage({
      id: 701,
      buffer_id: "channel:4",
      server_connection_id: 1,
      channel_membership_id: 4,
      nick: "akash",
      body: "one persisted unread",
      unread_count: 1,
      mention_count: 0,
    })
    act(() => {
      realtimeHandlers.onBufferMessage(message)
      realtimeHandlers.onBufferMessage(message)
      realtimeHandlers.onBufferMessage(canonicalMessage({
        id: 702,
        buffer_id: "channel:4",
        server_connection_id: 1,
        channel_membership_id: 4,
        kind: "command",
        body: "WHOIS akash",
        metadata: {command_id: "whois-unread", command_status: "sent"},
      }))
      realtimeHandlers.onBufferMessage(canonicalMessage({
        id: 702,
        buffer_id: "channel:4",
        server_connection_id: 1,
        channel_membership_id: 4,
        kind: "command",
        body: "WHOIS akash",
        metadata: {command_id: "whois-unread", command_status: "completed"},
      }))
    })

    expect(screen.getByLabelText("1 unread message in #zulu")).toBeInTheDocument()
    expect(screen.queryByLabelText("2 unread messages in #zulu")).not.toBeInTheDocument()
  })

  test("does not inflate authoritative unread counts when replaying an event after bootstrap", async () => {
    const seedClient = directMessageApiClient()
    const initial = await seedClient.bootstrap()
    const refreshed = structuredClone(initial)
    const zulu = refreshed.buffers.find((buffer) => buffer.buffer_id === "channel:4")
    zulu.unread_count = 1
    zulu.mention_count = 0
    let resolveRefresh
    const refresh = new Promise((resolve) => { resolveRefresh = resolve })
    const apiClient = {
      ...seedClient,
      bootstrap: vi.fn().mockResolvedValueOnce(initial).mockReturnValueOnce(refresh),
      bufferMessages: vi.fn().mockResolvedValue({messages: []}),
    }
    let realtimeHandlers

    render(
      <TopicsClubApp
        apiClient={apiClient as any}
        currentUser={{id: 1, email: "mira@example.com"}}
        developerOauth={true}
        realtimeClientFactory={({handlers}) => {
          realtimeHandlers = handlers
          return fakeRealtimeClient(vi.fn().mockResolvedValue({}))
        }}
      />
    )

    expect(await screen.findByRole("heading", {name: "Zed"})).toBeInTheDocument()
    act(() => realtimeHandlers.onJoinOk())
    act(() => realtimeHandlers.onBufferMessage(canonicalMessage({
      id: 703,
      buffer_id: "channel:4",
      server_connection_id: 1,
      channel_membership_id: 4,
      nick: "akash",
      body: "queued during refresh",
      unread_count: 1,
      mention_count: 0,
    })))
    await act(async () => resolveRefresh(refreshed))

    expect(await screen.findByLabelText("1 unread message in #zulu")).toBeInTheDocument()
    expect(screen.queryByLabelText("2 unread messages in #zulu")).not.toBeInTheDocument()
  })

  test("transfers active-buffer ownership before handling messages from the channel just left", async () => {
    const user = userEvent.setup()
    const apiClient = directMessageApiClient()
    const push = vi.fn().mockResolvedValue({})
    let realtimeHandlers

    render(
      <TopicsClubApp
        apiClient={apiClient as any}
        currentUser={{id: 1, email: "mira@example.com"}}
        developerOauth={true}
        realtimeClientFactory={({handlers}) => {
          realtimeHandlers = handlers
          return fakeRealtimeClient(push)
        }}
      />
    )

    const nav = screen.getByRole("navigation", {name: "Joined topics"})
    await user.click(await within(nav).findByText("#zulu"))
    expect(await screen.findByRole("heading", {name: "#zulu"})).toBeInTheDocument()

    act(() => {
      fireEvent.click(within(nav).getByText("#alpha"))
      realtimeHandlers.onBufferMessage(canonicalMessage({
        id: 704,
        buffer_id: "channel:4",
        server_connection_id: 1,
        channel_membership_id: 4,
        nick: "akash",
        body: "arrived while switching channels",
        unread_count: 1,
        mention_count: 0,
      }))
    })

    expect(screen.getByRole("heading", {name: "#alpha"})).toBeInTheDocument()
    expect(screen.getByLabelText("1 unread message in #zulu")).toBeInTheDocument()
    expect(push).not.toHaveBeenCalledWith("buffer:read", {buffer_id: "channel:4"})
  })

  test("uses the server action menu for reconnect and disconnect actions", async () => {
    const user = userEvent.setup()
    mockBootstrapFetch()
    const push = vi.fn((event) => {
      if (event === "server:reconnect") {
        return Promise.resolve(canonicalServerStatus("connecting"))
      }

      return Promise.resolve(canonicalServerStatus("disconnected"))
    })
    const client = fakeRealtimeClient(push)

    render(
      <TopicsClubApp
        currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}}
        developerOauth={true}
        realtimeClientFactory={() => client}
      />
    )

    expect(await screen.findByRole("heading", {name: "#testing"})).toBeInTheDocument()

    await user.click(screen.getByRole("button", {name: "Server actions for local"}))
    await user.click(screen.getByRole("menuitem", {name: "Connect or reconnect"}))

    expect(push).toHaveBeenCalledWith("server:reconnect", {server_connection_id: 42})

    await user.click(screen.getByRole("button", {name: "Server actions for local"}))
    await user.click(screen.getByRole("menuitem", {name: "Disconnect"}))

    expect(push).toHaveBeenCalledWith("server:disconnect", {server_connection_id: 42})

    await user.click(screen.getByRole("button", {name: /^local$/i}))
    expect(await screen.findByText("Server disconnected")).toBeInTheDocument()

    await user.click(screen.getByRole("button", {name: "Reconnect"}))
    expect(push).toHaveBeenLastCalledWith("server:reconnect", {server_connection_id: 42})
  })

  test("edits a server connection from the server action menu", async () => {
    const user = userEvent.setup()
    mockBootstrapFetch()

    render(<TopicsClubApp currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}} developerOauth={true} />)

    expect(await screen.findByRole("heading", {name: "#testing"})).toBeInTheDocument()

    await user.click(screen.getByRole("button", {name: "Server actions for local"}))
    await user.click(screen.getByRole("menuitem", {name: "Edit connection"}))

    const dialog = screen.getByRole("dialog", {name: "Edit connection"})
    expect(within(dialog).queryByLabelText("Server")).not.toBeInTheDocument()
    expect(within(dialog).queryByLabelText("IRC account name")).not.toBeInTheDocument()
    await user.clear(within(dialog).getByLabelText("Port"))
    await user.type(within(dialog).getByLabelText("Port"), "6697")
    await user.click(within(dialog).getByLabelText("TLS"))
    await user.clear(within(dialog).getByLabelText("Nickname"))
    await user.type(within(dialog).getByLabelText("Nickname"), "mira2")
    await user.click(within(dialog).getByRole("button", {name: "Save"}))

    await waitFor(() =>
      expect(globalThis.fetch).toHaveBeenCalledWith(
        "/api/connections/42",
        expect.objectContaining({
          method: "PUT",
          body: JSON.stringify({
            connection: {name: "local", host: "127.0.0.1", port: 6697, use_tls: true, nickname: "mira2"},
          }),
        })
      )
    )
    const nav = screen.getByRole("navigation", {name: "Joined topics"})
    expect(within(nav).getByText("local")).toBeInTheDocument()
    expect(screen.getAllByText("on 127.0.0.1").length).toBeGreaterThan(0)
  })

  test("takes an unavailable channel to its server remedy and reconnects with a random nickname", async () => {
    const user = userEvent.setup()
    mockBootstrapFetch({
      connectionStatus: "errored",
      connectionNickname: "bad.nick@example",
      serverMessages: [
        {
          id: 109,
          buffer_id: "server:42",
          server_connection_id: 42,
          nick: null,
          body: "Looking up your hostname...",
          kind: "system",
          metadata: {},
          occurred_at: "2026-05-13T10:00:00Z",
        },
        {
          id: 110,
          buffer_id: "server:42",
          server_connection_id: 42,
          nick: null,
          body: "Erroneous Nickname",
          kind: "error",
          metadata: {
            connection_issue: {
              code: "invalid_nickname",
              title: "Nickname is not valid",
              summary: "Erroneous Nickname",
              edit_focus: "nickname",
              irc_code: "432",
            },
          },
          occurred_at: "2026-05-13T10:01:00Z",
        },
      ],
    })
    const push = vi.fn((event) => Promise.resolve(
      canonicalServerStatus(event === "server:disconnect" ? "disconnected" : "connecting")
    ))

    render(
      <TopicsClubApp
        currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}}
        developerOauth={true}
        realtimeClientFactory={() => fakeRealtimeClient(push)}
      />
    )

    expect(await screen.findByRole("heading", {name: "#testing"})).toBeInTheDocument()
    expect(screen.getByLabelText("Message composer")).toHaveAttribute("readonly")
    await user.click(screen.getByRole("button", {name: "View issue"}))

    const issueHeading = await screen.findByRole("heading", {name: "Nickname is not valid"})
    const precedingMessage = screen.getByText("Looking up your hostname...")
    expect(Boolean(precedingMessage.compareDocumentPosition(issueHeading) & Node.DOCUMENT_POSITION_FOLLOWING)).toBe(true)
    expect(screen.queryByText("Erroneous Nickname")).not.toBeInTheDocument()
    expect(screen.getByText("Use a random nickname and reconnect now, or edit the connection to choose one yourself.")).toBeInTheDocument()
    expect(screen.queryByText("Connection error. Reconnect to resume messages.")).not.toBeInTheDocument()
    expect(screen.getByRole("button", {name: "Edit connection"})).toBeInTheDocument()
    expect(screen.queryByRole("button", {name: "Reconnect"})).not.toBeInTheDocument()
    await user.click(screen.getByRole("button", {name: "Choose a random nickname"}))

    await waitFor(() => expect(globalThis.fetch).toHaveBeenCalledWith(
      "/api/connections/42",
      expect.objectContaining({method: "PUT"})
    ))
    const updateCall = vi.mocked(globalThis.fetch).mock.calls.find(([path, options]) =>
      path === "/api/connections/42" && options?.method === "PUT"
    )
    const updateBody = JSON.parse(String(updateCall?.[1]?.body))
    expect(updateBody.connection).toMatchObject({name: "local", host: "127.0.0.1"})
    expect(updateBody.connection.nickname).toMatch(/^guest_[a-z0-9]{6}$/)

    await waitFor(() => expect(push.mock.calls.map(([event]) => event)).toEqual([
      "server:disconnect",
      "server:reconnect",
    ]))
  })

  test("confirms leaving a server from the server action menu", async () => {
    const user = userEvent.setup()
    mockBootstrapFetch()

    render(<TopicsClubApp currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}} developerOauth={true} />)

    expect(await screen.findByRole("heading", {name: "#testing"})).toBeInTheDocument()

    await user.click(screen.getByRole("button", {name: "Server actions for local"}))
    await user.click(screen.getByRole("menuitem", {name: "Leave server"}))

    const dialog = screen.getByRole("dialog", {name: "Leave server"})
    expect(within(dialog).getByText(/Remove local and its joined topics/i)).toBeInTheDocument()
    await user.click(within(dialog).getByRole("button", {name: "Leave"}))

    await waitFor(() =>
      expect(globalThis.fetch).toHaveBeenCalledWith(
        "/api/connections/42",
        expect.objectContaining({method: "DELETE", body: "{}"})
      )
    )
    expect(await screen.findByRole("heading", {name: "Find your next conversation."})).toBeInTheDocument()
    expect(screen.queryByRole("button", {name: /#testing/i})).not.toBeInTheDocument()
  })

  test.each([
    {server_connection_id: 42},
    {
      type: "server:deleted",
      version: 1,
      event_id: "server_deleted:99:1",
      occurred_at: "2026-05-13T10:00:00Z",
      server_connection_id: 99,
    },
  ])("keeps a server when deletion acknowledgement is not exact: $server_connection_id", async (deleteResponse) => {
    const user = userEvent.setup()
    mockBootstrapFetch({deleteResponse})

    render(<TopicsClubApp currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}} developerOauth={true} />)

    expect(await screen.findByRole("heading", {name: "#testing"})).toBeInTheDocument()
    await user.click(screen.getByRole("button", {name: "Server actions for local"}))
    await user.click(screen.getByRole("menuitem", {name: "Leave server"}))
    await user.click(within(screen.getByRole("dialog", {name: "Leave server"})).getByRole("button", {name: "Leave"}))

    await waitFor(() => expect(globalThis.fetch).toHaveBeenCalledWith(
      "/api/connections/42",
      expect.objectContaining({method: "DELETE"})
    ))
    expect(screen.getByRole("heading", {name: "#testing"})).toBeInTheDocument()
  })

  test("browses, filters, and joins channels from a server directory", async () => {
    const user = userEvent.setup()
    mockBootstrapFetch()
    let realtimeHandlers
    const push = vi.fn((event, payload) => {
      if (event === "server:list") {
        const quietSearch = payload?.query === "quiet"
        const page = payload?.page || 1

        return Promise.resolve({
          directory: {
            server_connection_id: 42,
            server_name: "local",
            server_host: "127.0.0.1",
            page,
            page_size: 25,
            query: quietSearch ? "quiet" : "",
            total_channels: quietSearch ? 1 : 30,
            total_pages: quietSearch ? 1 : 2,
            channels: quietSearch
              ? [{channel: "~quiet", users: 4, topic: "A slower room"}]
              : [
                  {channel: "#elixir", users: 42, topic: "Phoenix, OTP, and releases"},
                  {channel: "~quiet", users: 4, topic: "A slower room"},
                ],
          },
        })
      }

      return Promise.resolve({ok: true})
    })
    const client = fakeRealtimeClient(push)

    render(
      <TopicsClubApp
        currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}}
        developerOauth={true}
        realtimeClientFactory={({handlers}) => {
          realtimeHandlers = handlers
          return client
        }}
      />
    )

    await user.click(await screen.findByRole("button", {name: "Browse channels on local"}))

    expect(push).toHaveBeenCalledWith("server:list", {page: 1, query: "", server_connection_id: 42})
    expect(await screen.findByRole("heading", {name: "Channels on local"})).toBeInTheDocument()
    expect(window.location.pathname).toBe("/chat/42/%2Flist")
    expect(screen.getByText("Phoenix, OTP, and releases")).toBeInTheDocument()
    expect(screen.getByText("42 people")).toBeInTheDocument()
    expect(screen.getAllByText("Page 1 of 2")).toHaveLength(2)

    await user.click(screen.getAllByRole("button", {name: "Next channel page"})[0])
    await waitFor(() => expect(push).toHaveBeenLastCalledWith(
      "server:list",
      {page: 2, query: "", server_connection_id: 42}
    ))
    expect(screen.getAllByText("Page 2 of 2")).toHaveLength(2)
    expect(window.location.search).toBe("?p=2")

    await user.type(screen.getByLabelText("Search this server"), "quiet")
    await user.click(screen.getByRole("button", {name: "Search"}))
    await waitFor(() => expect(push).toHaveBeenLastCalledWith(
      "server:list",
      {page: 1, query: "quiet", server_connection_id: 42}
    ))
    expect(window.location.search).toBe("?q=quiet")
    expect(screen.queryByText("#elixir")).not.toBeInTheDocument()
    expect(screen.getByText("~quiet")).toBeInTheDocument()

    const quietRow = screen.getByText("~quiet").closest("article")
    await user.click(within(quietRow).getByRole("button", {name: "Join"}))

    expect(globalThis.fetch).toHaveBeenCalledWith(
      "/api/connections/42/channels",
      expect.objectContaining({method: "POST", body: JSON.stringify({channel: "~quiet"})})
    )
    expect(await screen.findByRole("heading", {name: "~quiet"})).toBeInTheDocument()
    expect(within(screen.getByRole("navigation", {name: "Joined topics"})).getByText("~quiet")).toBeInTheDocument()

    realtimeHandlers.onBufferLeft(canonicalBufferLeft("channel:12"))

    expect(await screen.findByRole("heading", {name: "127.0.0.1", level: 2})).toBeInTheDocument()
    expect(screen.queryByRole("button", {name: /~quiet/})).not.toBeInTheDocument()
  })

  test("does not recreate a rejected directory join when buffer left arrives before HTTP", async () => {
    const user = userEvent.setup()
    let realtimeHandlers
    let resolveJoinResponse
    const joinResponsePromise = new Promise((resolve) => {
      resolveJoinResponse = resolve
    })

    mockBootstrapFetch({joinResponsePromise})

    const push = vi.fn((event) => {
      if (event === "server:list") {
        return Promise.resolve({
          directory: {
            server_connection_id: 42,
            server_name: "local",
            server_host: "127.0.0.1",
            channels: [{channel: "#elixir", users: 42, topic: "Phoenix and OTP"}],
          },
        })
      }

      return Promise.resolve({ok: true})
    })

    render(
      <TopicsClubApp
        currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}}
        developerOauth={true}
        realtimeClientFactory={({handlers}) => {
          realtimeHandlers = handlers
          return fakeRealtimeClient(push)
        }}
      />
    )

    await user.click(await screen.findByRole("button", {name: "Browse channels on local"}))
    const elixirRow = (await screen.findByText("#elixir")).closest("article")
    await user.click(within(elixirRow).getByRole("button", {name: "Join"}))

    realtimeHandlers.onBufferLeft(canonicalBufferLeft("channel:12"))

    resolveJoinResponse({
      ok: true,
      json: async () => ({
        channel: {
          id: 12,
          connection_id: 42,
          channel: "#elixir",
          unread_count: 0,
          mention_count: 0,
          mention_notifications_enabled: true,
          notification_preference_revision: 0,
        },
      }),
    })

    expect(await screen.findByText(/Could not join #elixir/)).toBeInTheDocument()
    expect(screen.queryByRole("heading", {name: "#elixir", level: 1})).not.toBeInTheDocument()
    expect(within(screen.getByRole("navigation", {name: "Joined topics"})).queryByText("#elixir")).not.toBeInTheDocument()

    await user.click(within(elixirRow).getByRole("button", {name: "Join"}))

    expect(await screen.findByRole("heading", {name: "#elixir", level: 1})).toBeInTheDocument()
    expect(within(screen.getByRole("navigation", {name: "Joined topics"})).getByText("#elixir")).toBeInTheDocument()
  })

  test("does not suppress a valid retry when another buffer leaves", async () => {
    const user = userEvent.setup()
    let realtimeHandlers
    let resolveFirstJoin
    let resolveRetry
    const firstJoin = new Promise((resolve) => { resolveFirstJoin = resolve })
    const retry = new Promise((resolve) => { resolveRetry = resolve })
    mockBootstrapFetch({joinResponsePromise: [firstJoin, retry]})

    const push = vi.fn((event) =>
      event === "server:list"
        ? Promise.resolve({directory: {server_connection_id: 42, server_name: "local", server_host: "127.0.0.1", channels: [{channel: "#elixir", users: 42, topic: "Phoenix and OTP"}]}})
        : Promise.resolve({ok: true})
    )

    render(
      <TopicsClubApp
        currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}}
        developerOauth={true}
        realtimeClientFactory={({handlers}) => {
          realtimeHandlers = handlers
          return fakeRealtimeClient(push)
        }}
      />
    )

    await user.click(await screen.findByRole("button", {name: "Browse channels on local"}))
    const row = (await screen.findByText("#elixir")).closest("article")
    await user.click(within(row).getByRole("button", {name: "Join"}))
    realtimeHandlers.onBufferLeft(canonicalBufferLeft("channel:12"))
    resolveFirstJoin(joinResponse(12, "#elixir"))
    expect(await screen.findByText(/Could not join #elixir/)).toBeInTheDocument()

    await user.click(within(row).getByRole("button", {name: "Join"}))
    realtimeHandlers.onBufferLeft(canonicalBufferLeft("channel:7"))
    resolveRetry(joinResponse(12, "#elixir"))

    expect(await screen.findByRole("heading", {name: "#elixir", level: 1})).toBeInTheDocument()
  })

  test("does not reopen a directory after the user navigates away from a pending list", async () => {
    const user = userEvent.setup()
    mockBootstrapFetch()
    let resolveList
    const push = vi.fn((event) => {
      if (event === "server:list") return new Promise((resolve) => { resolveList = resolve })
      return Promise.resolve({ok: true})
    })
    const client = fakeRealtimeClient(push)

    render(
      <TopicsClubApp
        currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}}
        developerOauth={true}
        realtimeClientFactory={() => client}
      />
    )

    await user.click(await screen.findByRole("button", {name: "Browse channels on local"}))
    expect(screen.getByRole("status", {name: /Loading channels from local/i})).toBeInTheDocument()

    const nav = screen.getByRole("navigation", {name: "Joined topics"})
    await user.click(within(nav).getByRole("button", {name: "#testing"}))
    resolveList({
      directory: {
        server_connection_id: 42,
        server_name: "local",
        channels: [{channel: "#late", users: 10, topic: "Late result"}],
      },
    })

    await waitFor(() => expect(screen.getByRole("heading", {name: "#testing"})).toBeInTheDocument())
    expect(screen.queryByText("#late")).not.toBeInTheDocument()
    expect(screen.queryByRole("heading", {name: "Channels on local"})).not.toBeInTheDocument()
  })

  test("keeps join errors separate and preserves advertised channel prefixes", async () => {
    const user = userEvent.setup()
    mockBootstrapFetch({joinOk: false})
    const push = vi.fn((event) => {
      if (event === "server:list") {
        return Promise.resolve({
          directory: {
            server_connection_id: 42,
            server_name: "local",
            channels: [{channel: "&local", users: 3, topic: "Local-only conversation"}],
          },
        })
      }

      return Promise.resolve({ok: true})
    })
    const client = fakeRealtimeClient(push)

    render(
      <TopicsClubApp
        currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}}
        developerOauth={true}
        realtimeClientFactory={() => client}
      />
    )

    await user.click(await screen.findByRole("button", {name: "Browse channels on local"}))
    const channelRow = (await screen.findByText("&local")).closest("article")
    await user.click(within(channelRow).getByRole("button", {name: "Join"}))

    expect(globalThis.fetch).toHaveBeenCalledWith(
      "/api/connections/42/channels",
      expect.objectContaining({method: "POST", body: JSON.stringify({channel: "&local"})})
    )
    expect(await screen.findByText("Channel was not joined")).toBeInTheDocument()
    expect(screen.getByText(/Check the name and channel permissions, then try Join again/)).toBeInTheDocument()
    expect(screen.queryByText("The channel list did not load")).not.toBeInTheDocument()
    expect(screen.getByRole("heading", {name: "Channels on local"})).toBeInTheDocument()
  })

  test("does not reopen a directory after navigating away from a pending /list request", async () => {
    const user = userEvent.setup()
    mockBootstrapFetch()
    let resolveList
    const push = vi.fn((event) => {
      if (event === "server:list") return new Promise((resolve) => { resolveList = resolve })
      return Promise.resolve({ok: true})
    })
    const client = fakeRealtimeClient(push)
    let realtimeHandlers

    render(
      <TopicsClubApp
        currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}}
        developerOauth={true}
        realtimeClientFactory={({handlers}) => {
          realtimeHandlers = handlers
          return client
        }}
      />
    )

    expect(await screen.findByRole("heading", {name: "#testing"})).toBeInTheDocument()
    realtimeHandlers.onJoinOk()
    await user.type(screen.getByLabelText("Message composer"), "/list")
    await user.click(screen.getByRole("button", {name: "Send"}))
    expect(screen.getByRole("status", {name: /Loading channels from local/i})).toBeInTheDocument()
    await user.click(screen.getByRole("button", {name: "local"}))

    resolveList({
      directory: {
        server_connection_id: 42,
        server_name: "local",
        channels: [{channel: "#late", users: 10, topic: "Late result"}],
      },
    })

    expect(await screen.findByRole("heading", {name: "127.0.0.1", level: 2})).toBeInTheDocument()
    expect(screen.queryByText("#late")).not.toBeInTheDocument()
    expect(screen.queryByRole("heading", {name: "Channels on local"})).not.toBeInTheDocument()
  })

  test("preserves the directory while a reconnect bootstrap refreshes buffers", async () => {
    const user = userEvent.setup()
    mockBootstrapFetch()
    const push = vi.fn((event) => event === "server:list"
      ? Promise.resolve({
          directory: {
            server_connection_id: 42,
            server_name: "local",
            server_host: "127.0.0.1",
            page: 1,
            page_size: 25,
            query: "",
            total_channels: 1,
            total_pages: 1,
            channels: [{channel: "#elixir", users: 42, topic: "Phoenix and OTP"}],
          },
        })
      : Promise.resolve({ok: true}))
    let realtimeHandlers

    render(
      <TopicsClubApp
        currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}}
        developerOauth={true}
        realtimeClientFactory={({handlers}) => {
          realtimeHandlers = handlers
          return fakeRealtimeClient(push)
        }}
      />
    )

    await user.click(await screen.findByRole("button", {name: "Browse channels on local"}))
    expect(await screen.findByText("#elixir")).toBeInTheDocument()

    await act(async () => realtimeHandlers.onJoinOk())

    await waitFor(() => {
      const bootstrapCalls = globalThis.fetch.mock.calls.filter(([path]) => path === "/api/bootstrap")
      expect(bootstrapCalls).toHaveLength(2)
    })
    expect(screen.getByRole("heading", {name: "Channels on local"})).toBeInTheDocument()
    expect(screen.getByText("#elixir")).toBeInTheDocument()
    expect(window.location.pathname).toBe("/chat/42/%2Flist")
  })

  test("opens the active server directory from the /list command", async () => {
    const user = userEvent.setup()
    mockBootstrapFetch()
    let resolveList
    const push = vi.fn((event) => {
      if (event === "server:list") return new Promise((resolve) => { resolveList = resolve })

      return Promise.resolve({ok: true})
    })
    const client = fakeRealtimeClient(push)
    let realtimeHandlers

    render(
      <TopicsClubApp
        currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}}
        developerOauth={true}
        realtimeClientFactory={({handlers}) => {
          realtimeHandlers = handlers
          return client
        }}
      />
    )

    expect(await screen.findByRole("heading", {name: "#testing"})).toBeInTheDocument()
    realtimeHandlers.onJoinOk()

    await user.type(screen.getByLabelText("Message composer"), "/list")
    await user.click(screen.getByRole("button", {name: "Send"}))

    expect(push).toHaveBeenCalledWith("server:list", {page: 1, query: "", server_connection_id: 42})
    expect(screen.getByRole("heading", {name: "Channels on local"})).toBeInTheDocument()
    expect(screen.getByRole("status", {name: /Loading channels from local/i})).toBeInTheDocument()
    expect(screen.getByText(/cached for up to one hour/i)).toBeInTheDocument()
    expect(screen.queryByRole("button", {name: "Refresh list"})).not.toBeInTheDocument()
    expect(screen.queryByLabelText("Message composer")).not.toBeInTheDocument()

    resolveList({
      directory: {
        server_connection_id: 42,
        server_name: "local",
        server_host: "127.0.0.1",
        channels: [{channel: "#elixir", users: 42, topic: "Phoenix, OTP, and releases"}],
      },
    })

    expect(await screen.findByText("#elixir")).toBeInTheDocument()
  })

  test("shows slash command suggestions from the chat composer", async () => {
    const user = userEvent.setup()
    mockBootstrapFetch()

    render(<TopicsClubApp currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}} developerOauth={true} />)

    expect(await screen.findByRole("heading", {name: "#testing"})).toBeInTheDocument()
    await user.type(screen.getByLabelText("Message composer"), "/jo")

    const suggestions = screen.getByRole("listbox", {name: "Slash command suggestions"})
    expect(within(suggestions).getByRole("option", {name: /\/join/i})).toBeInTheDocument()
  })

  test("runs slash command submissions through the realtime client", async () => {
    const user = userEvent.setup()
    mockBootstrapFetch()
    const push = vi.fn().mockResolvedValue({command: {name: "join", args: ["#ops"]}})
    const client = fakeRealtimeClient(push)
    let realtimeHandlers

    render(
      <TopicsClubApp
        currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}}
        developerOauth={true}
        realtimeClientFactory={({handlers}) => {
          realtimeHandlers = handlers
          return client
        }}
      />
    )

    expect(await screen.findByRole("heading", {name: "#testing"})).toBeInTheDocument()
    realtimeHandlers.onJoinOk()

    await user.type(screen.getByLabelText("Message composer"), "/join #ops")
    await user.click(screen.getByRole("button", {name: "Send"}))

    expect(push).toHaveBeenCalledWith(
      "command:run",
      expect.objectContaining({
        input: "/join #ops",
        buffer_id: "channel:7",
      })
    )
    await waitFor(() => expect(screen.getByLabelText("Message composer")).toHaveValue(""))
    expect(screen.queryByText("Command accepted.")).not.toBeInTheDocument()
    expect(screen.queryByText("/join #ops")).not.toBeInTheDocument()
  })

  test("shows typed backend command errors and keeps the draft for correction", async () => {
    const user = userEvent.setup()
    mockBootstrapFetch()
    const push = vi.fn().mockRejectedValue({
      reason: "invalid_arguments",
      error: {message: "Arguments do not match WHOIS <nick>.", usage: "WHOIS <nick>"},
    })
    const client = fakeRealtimeClient(push)
    let realtimeHandlers

    render(
      <TopicsClubApp
        currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}}
        developerOauth={true}
        realtimeClientFactory={({handlers}) => {
          realtimeHandlers = handlers
          return client
        }}
      />
    )

    expect(await screen.findByRole("heading", {name: "#testing"})).toBeInTheDocument()
    realtimeHandlers.onJoinOk()

    const composer = screen.getByLabelText("Message composer")
    await user.type(composer, "/quote WHOIS")
    await user.click(screen.getByRole("button", {name: "Send"}))

    expect(await screen.findByRole("alert")).toHaveTextContent(
      "Arguments do not match WHOIS <nick>. Usage: WHOIS <nick>"
    )
    expect(composer).toHaveValue("/quote WHOIS")
  })

  test("clears a stale command error when Discover opens an already-joined channel", async () => {
    const user = userEvent.setup()
    mockBootstrapFetch({includeDiscovery: true})
    const client = fakeRealtimeClient(vi.fn().mockRejectedValue({reason: "unexpected"}))
    let realtimeHandlers

    render(
      <TopicsClubApp
        currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}}
        developerOauth={true}
        realtimeClientFactory={({handlers}) => {
          realtimeHandlers = handlers
          return client
        }}
      />
    )

    expect(await screen.findByRole("heading", {name: "#testing"})).toBeInTheDocument()
    realtimeHandlers.onJoinOk()

    await user.type(screen.getByLabelText("Message composer"), "/quote WHOIS")
    await user.click(screen.getByRole("button", {name: "Send"}))
    expect(await screen.findByRole("alert")).toHaveTextContent("The IRC command could not be sent.")

    await user.click(screen.getByRole("button", {name: /discover/i}))
    await user.click(await screen.findByRole("button", {name: "Join #testing on Local IRC"}))

    expect(await screen.findByRole("heading", {name: "#testing"})).toBeInTheDocument()
    expect(screen.queryByText("The IRC command could not be sent.")).not.toBeInTheDocument()
  })

  test("keeps slash command suggestions hidden for normal messages", async () => {
    const user = userEvent.setup()
    mockTopicsFetch()

    render(<TopicsClubApp currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}} developerOauth={true} />)

    await user.type(screen.getByLabelText("Message composer"), "hello /join")

    expect(screen.queryByRole("listbox", {name: "Slash command suggestions"})).not.toBeInTheDocument()
  })

  test("keeps signed-in users on the public landing page unless they open chat", async () => {
    mockTopicsFetch()

    render(
      <TopicsClubApp
        appMode="landing"
        currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}}
        developerOauth={true}
        initialFeaturedChannels={featuredChannelFixtures}
      />
    )

    expect(await screen.findByRole("heading", {name: "Featured channels"})).toBeInTheDocument()
    expect(screen.getByRole("link", {name: "Open chat"})).toHaveAttribute("href", "/chat")
    expect(screen.queryByRole("navigation", {name: "Joined topics"})).not.toBeInTheDocument()
  })

})
