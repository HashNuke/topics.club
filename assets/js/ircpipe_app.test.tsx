import React from "react"
import {describe, expect, test, vi} from "vitest"
import {act, fireEvent, render, screen, waitFor, within} from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import IrcpipeApp, {appendTimelineMessage, trimMessagesToLimit, visibleTimelineMessages} from "./ircpipe_app.tsx"

const topicFixtures = [
  {id: "fixture-elixir", name: "#elixir", description: "Phoenix, OTP, releases, and production Elixir help.", server_host: "127.0.0.1", server_port: 6669, use_tls: false, channel: "#elixir", members: 426},
  {id: "fixture-phoenix", name: "#phoenix", description: "LiveView patterns, web UI questions, and framework support.", server_host: "127.0.0.1", server_port: 6669, use_tls: false, channel: "#phoenix", members: 188},
  {id: "fixture-linux", name: "#linux", description: "Daily Linux discussion and troubleshooting.", server_host: "127.0.0.1", server_port: 6669, use_tls: false, channel: "#linux", members: 931},
]

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

function mockTopicsFetch() {
  vi.spyOn(globalThis, "fetch").mockResolvedValue({
    ok: true,
    json: async () => ({topics: topicFixtures}),
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

function mockBootstrapFetch({
  afterMessages = [],
  bufferMessageResponses = null,
  bootstrapChannelMessages = null,
  channelMentionCount = 0,
  channelUnreadCount = 0,
  connectionStatus = "connected",
  includeDiscovery = false,
  joinResponsePromise = null,
  joinOk = true,
  messageCursorsByBuffer = {"channel:7": 99},
  push = {configured: false, vapid_public_key: null},
  pushSubscriptionOk = true,
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
      return {
        ok: true,
        json: async () => ({
          connection: {
            id: 42,
            name: "edited",
            host: "irc.edited.test",
            port: 6697,
            use_tls: true,
            nickname: "mira2",
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
        json: async () => ({deleted: {type: "server:deleted", server_connection_id: 42}}),
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
            {
              id: 50,
              buffer_id: "channel:7",
              nick: "mira",
              body: "older from history",
              kind: "message",
              mentioned: false,
              occurred_at: "2026-05-13T09:30:00Z",
            },
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
        json: async () => ({messages: await Promise.resolve(messagesOrPromise)}),
      }
    }

    if (path === "/api/bootstrap") {
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
            {name: "/join", usage: "/join #channel", description: "Join a channel", contexts: ["server", "channel"], availability: "enabled"},
            {name: "/list", usage: "/list", description: "Browse channels", contexts: ["server", "channel"], availability: "enabled"},
            {name: "/me", usage: "/me action", description: "Send an action", contexts: ["channel"], availability: "enabled"},
          ],
          connections: [
            {
              id: 42,
              name: "local",
              host: "127.0.0.1",
              port: 6669,
              use_tls: false,
              nickname: "mira",
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
            "channel:7": bootstrapChannelMessages || [
              {
                id: 99,
                buffer_id: "channel:7",
                nick: "akash",
                body: "loaded from bootstrap",
                kind: "message",
                mentioned: false,
                occurred_at: "2026-05-13T10:00:00Z",
              },
            ],
          },
          message_cursors_by_buffer: messageCursorsByBuffer,
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
      return {ok: true, json: async () => ({connections: [], buffers: [], direct_message_tombstones: [], messages_by_buffer: {}, users_by_buffer: {}, topics: [], push: {configured: false, vapid_public_key: null, session_generation: "test-session", session_installation_id: null, session_registration_confirmed: false}})}
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
          direct_message_tombstones: [],
          messages_by_buffer: {},
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
          direct_message_tombstones: [],
          messages_by_buffer: {},
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

function directMessageApiClient() {
  return {
    topics: vi.fn().mockResolvedValue({topics: []}),
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
        "direct:9": [{id: 31, buffer_id: "direct:9", nick: "Zed", body: "private hello"}],
      },
      message_cursors_by_buffer: {},
      users_by_buffer: {},
      command_catalog: [{name: "/msg", contexts: ["channel"]}],
    }),
  }
}

describe("IrcpipeApp UI prototype", () => {
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

  test("loads older channel history when scrolling near the top", async () => {
    mockBootstrapFetch()

    render(<IrcpipeApp currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}} developerOauth={true} />)

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

  test("shows topic-first landing cards with channel and server labels", async () => {
    mockTopicsFetch()

    render(<IrcpipeApp currentUser={null} developerOauth={true} />)

    expect(await screen.findByRole("heading", {name: "Community chat"})).toBeInTheDocument()
    expect(await screen.findByRole("button", {name: /#elixir/i})).toHaveTextContent("on 127.0.0.1")
    expect(screen.getByRole("link", {name: "Open chat"})).toHaveAttribute("href", "/chat")
    expect(screen.getByRole("link", {name: "Developer OAuth"})).toHaveAttribute("href", "/auth/developer")
  })

  test("asks unauthenticated users to sign in before joining a topic", async () => {
    const user = userEvent.setup()
    mockTopicsFetch()

    render(<IrcpipeApp currentUser={null} developerOauth={true} />)

    await user.click(await screen.findByRole("button", {name: /#phoenix/i}))

    const dialog = screen.getByRole("dialog", {name: "Sign in to join"})

    expect(within(dialog).getByRole("heading", {name: "Sign in to join"})).toBeInTheDocument()
    expect(within(dialog).getByRole("link", {name: "Developer OAuth"})).toHaveAttribute(
      "href",
      "/auth/developer?topic=fixture-phoenix"
    )
  })

  test("opens discover and joins a backend topic in the app shell", async () => {
    const user = userEvent.setup()
    mockDiscoveryFetch()

    render(<IrcpipeApp currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}} developerOauth={true} />)

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

    render(<IrcpipeApp currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}} developerOauth={true} />)

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

    render(<IrcpipeApp currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}} developerOauth={true} />)

    expect(await screen.findByRole("heading", {name: "#testing"})).toBeInTheDocument()
    expect(screen.getByText("loaded from bootstrap")).toBeInTheDocument()
    expect(screen.getByLabelText("Message composer").tagName).toBe("TEXTAREA")

    const nav = screen.getByRole("navigation", {name: "Joined topics"})
    expect(within(nav).getByText("local")).toBeInTheDocument()
    expect(within(nav).getByText("#testing")).toBeInTheDocument()
    expect(globalThis.fetch).toHaveBeenCalledWith("/api/bootstrap", expect.objectContaining({credentials: "same-origin"}))
  })

  test("renders ordered private-message navigation, unread state, and peer context", async () => {
    const apiClient = directMessageApiClient()

    render(<IrcpipeApp apiClient={apiClient as any} currentUser={{id: 1, email: "mira@example.com"}} developerOauth={true} />)

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

  test("adds incoming private-message threads without stealing focus", async () => {
    mockBootstrapFetch()
    const client = fakeRealtimeClient(vi.fn())
    let realtimeHandlers

    render(
      <IrcpipeApp
        currentUser={{id: 1, email: "mira@example.com"}}
        developerOauth={true}
        realtimeClientFactory={({handlers}) => {
          realtimeHandlers = handlers
          return client
        }}
      />
    )

    expect(await screen.findByRole("heading", {name: "#testing"})).toBeInTheDocument()
    realtimeHandlers.onDirectMessageThread(directThreadPayload({
      connection: {id: 42, name: "local", host: "127.0.0.1", status: "connected", mention_notifications_enabled: true, notification_preference_revision: 0},
      buffer: {buffer_id: "direct:12", buffer_type: "direct_message", server_connection_id: 42, direct_message_thread_id: 12, direct_message_revision: 1, title: "akash", subtitle: "on 127.0.0.1", unread_count: 1, blocked: false},
      revision: 1,
    }))
    realtimeHandlers.onBufferMessage({id: 88, buffer_id: "direct:12", nick: "akash", body: "incoming DM"})

    expect(await screen.findByLabelText("1 unread message from akash")).toBeInTheDocument()
    expect(screen.getByRole("heading", {name: "#testing"})).toBeInTheDocument()

    const nav = screen.getByRole("navigation", {name: "Joined topics"})
    await userEvent.click(within(nav).getByText("akash"))
    expect(await screen.findByRole("heading", {name: "akash"})).toBeInTheDocument()
    expect(screen.getByText("incoming DM")).toBeInTheDocument()
  })

  test("ignores a delayed private-message close older than a reopen", async () => {
    const apiClient = directMessageApiClient()
    const client = fakeRealtimeClient(vi.fn())
    let realtimeHandlers

    render(
      <IrcpipeApp
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
      <IrcpipeApp
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
      <IrcpipeApp
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
      <IrcpipeApp
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
      messages_by_buffer: {},
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
      <IrcpipeApp
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
        <IrcpipeApp
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
        message: {type: "buffer:message", version: 1, event_id: "message:89", id: 89, buffer_id: "direct:12", server_connection_id: 42, direct_message_thread_id: 12, nick: "mira", body: "hello privately", occurred_at: "2026-08-26T00:00:00Z"},
      }))
    })
    const client = fakeRealtimeClient(push)
    let realtimeHandlers

    render(
      <IrcpipeApp
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
    expect(push).toHaveBeenCalledWith("command:run", expect.objectContaining({input: "/msg akash hello privately", buffer_id: "channel:7"}))
  })

  test("rejects a msg reply whose authoritative message body does not match the command", async () => {
    const user = userEvent.setup()
    mockBootstrapFetch()
    const push = vi.fn().mockResolvedValue(directThreadPayload({
      connection: {id: 42, name: "local", host: "127.0.0.1", port: 6669, use_tls: false, nickname: "mira", status: "connected", mention_notifications_enabled: true, notification_preference_revision: 0},
      buffer: {buffer_id: "direct:12", buffer_type: "direct_message", server_connection_id: 42, direct_message_thread_id: 12, direct_message_revision: 1, title: "akash", subtitle: "on 127.0.0.1", unread_count: 0, blocked: false},
      revision: 1,
      message: {type: "buffer:message", version: 1, event_id: "message:89", id: 89, buffer_id: "direct:12", server_connection_id: 42, direct_message_thread_id: 12, nick: "mira", body: "different body", occurred_at: "2026-08-26T00:00:00Z"},
    }))
    const client = fakeRealtimeClient(push)
    let realtimeHandlers

    render(
      <IrcpipeApp
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
      <IrcpipeApp
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
    expect(push).toHaveBeenCalledWith("direct_message:close", {buffer_id: "direct:9"})
  })

  test("renders IRC join events as channel meta messages", async () => {
    mockBootstrapFetch()
    let realtimeHandlers
    const client = fakeRealtimeClient(vi.fn())

    render(
      <IrcpipeApp
        currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}}
        developerOauth={true}
        realtimeClientFactory={({handlers}) => {
          realtimeHandlers = handlers
          return client
        }}
      />
    )

    expect(await screen.findByRole("heading", {name: "#testing"})).toBeInTheDocument()

    realtimeHandlers.onBufferMessage({
      type: "buffer:message",
      buffer_id: "channel:7",
      id: 206,
      nick: "dev23",
      body: "dev23 joined #elixir.",
      kind: "join",
      occurred_at: "2026-05-13T10:05:00Z",
    })

    expect(await screen.findByText("dev23 joined #elixir.")).toBeInTheDocument()
    expect(screen.queryByText("dev23:")).not.toBeInTheDocument()
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
        },
      ],
    })

    render(<IrcpipeApp currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}} developerOauth={true} />)

    expect(await screen.findByText("loaded from bootstrap")).toBeInTheDocument()
    expect(await screen.findByText("missed during bootstrap")).toBeInTheDocument()
    expect(globalThis.fetch).toHaveBeenCalledWith(
      "/api/buffer_messages?limit=50&buffer_id=channel%3A7",
      expect.objectContaining({credentials: "same-origin"})
    )
  })

  test("joins a requested backend topic by its id", async () => {
    mockResolvedLocalTopicFetch()
    window.history.pushState({}, "", "/chat?topic=101")

    render(<IrcpipeApp currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}} developerOauth={true} />)

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

    render(<IrcpipeApp currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}} developerOauth={true} />)

    expect(screen.getByRole("heading", {name: "Chat"})).toBeInTheDocument()
    expect(screen.queryByText(/placeholder chat until the IRC backend is wired/i)).not.toBeInTheDocument()
    expect(screen.queryByText("Phoenix, OTP, releases, and production Elixir help.")).not.toBeInTheDocument()
  })

  test("sends channel messages through the realtime client and replaces pending message", async () => {
    const user = userEvent.setup()
    mockBootstrapFetch()
    const push = vi.fn().mockResolvedValue({
      client_message_id: "client-reply",
      message: {
        type: "buffer:message",
        version: 1,
        event_id: "message:100",
        id: 100,
        buffer_id: "channel:7",
        server_connection_id: 42,
        channel_membership_id: 7,
        nick: "mira",
        body: "sent through socket",
        kind: "message",
        mentioned: false,
        occurred_at: "2026-05-13T10:01:00Z",
      },
    })
    const client = fakeRealtimeClient(push)
    let realtimeHandlers

    render(
      <IrcpipeApp
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
  })

  test("rejects a sent-message reply from a different server connection", async () => {
    const user = userEvent.setup()
    mockBootstrapFetch()
    const push = vi.fn().mockResolvedValue({
      message: {
        type: "buffer:message",
        version: 1,
        event_id: "message:100",
        id: 100,
        buffer_id: "channel:7",
        server_connection_id: 999,
        channel_membership_id: 7,
        nick: "mira",
        body: "wrong server",
        kind: "message",
        mentioned: false,
        occurred_at: "2026-05-13T10:01:00Z",
      },
    })
    const client = fakeRealtimeClient(push)
    let realtimeHandlers

    render(
      <IrcpipeApp
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
      <IrcpipeApp
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
      <IrcpipeApp
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
        message: {
          type: "buffer:message",
          version: 1,
          event_id: "message:101",
          id: 101,
          buffer_id: "channel:7",
          server_connection_id: 42,
          channel_membership_id: 7,
          nick: "mira",
          body: "try again",
          kind: "message",
          mentioned: false,
          occurred_at: "2026-05-13T10:02:00Z",
        },
      })
    const client = fakeRealtimeClient(push)
    let realtimeHandlers

    render(
      <IrcpipeApp
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
      <IrcpipeApp
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
    mockBootstrapFetch({connectionStatus: "connecting"})
    const push = vi.fn()
    const client = fakeRealtimeClient(push)
    let realtimeHandlers

    render(
      <IrcpipeApp
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

    expect(screen.getByRole("button", {name: "Send"})).toBeDisabled()
    expect(push).not.toHaveBeenCalled()
    expect(composer).toHaveValue("wait for irc")
    expect(screen.getByText("Reconnecting...")).toBeInTheDocument()
  })

  test("reconciles missed messages in order when an IRC server reconnects", async () => {
    let realtimeHandlers
    const client = fakeRealtimeClient(vi.fn())
    mockBootstrapFetch({
      connectionStatus: "connecting",
      messageCursorsByBuffer: {},
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
      <IrcpipeApp
        currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}}
        developerOauth={true}
        realtimeClientFactory={({handlers}) => {
          realtimeHandlers = handlers
          return client
        }}
      />
    )

    expect(await screen.findByText("loaded from bootstrap")).toBeInTheDocument()
    realtimeHandlers.onServerStatus({server_connection_id: 42, status: "connected"})

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
      messageCursorsByBuffer: {},
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
      <IrcpipeApp
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
      <IrcpipeApp
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
      expect(requests).toHaveLength(2)
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
      <IrcpipeApp
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
      <IrcpipeApp
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

    realtimeHandlers.onBufferMessage({
      ...sentCommand,
      type: "buffer:system",
      metadata: {command_id: "whois-race-1", command_status: "completed"},
    })

    await waitFor(() => expect(commandRow).toHaveAttribute("data-command-status", "completed"))
    resolveTail([sentCommand])
    await waitFor(() => expect(commandRow).toHaveAttribute("data-command-status", "completed"))
  })

  test("shows degraded connection health when the realtime join fails", async () => {
    mockBootstrapFetch()
    let realtimeHandlers
    const client = fakeRealtimeClient(vi.fn())

    render(
      <IrcpipeApp
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
      <IrcpipeApp
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
      <IrcpipeApp
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
      <IrcpipeApp
        currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}}
        developerOauth={true}
        realtimeClientFactory={({handlers}) => {
          realtimeHandlers = handlers
          return client
        }}
      />
    )

    expect(await screen.findByRole("heading", {name: "#testing"})).toBeInTheDocument()

    realtimeHandlers.onPresenceSync({
      buffer_id: "channel:7",
      users: [
        {nick: "mira", role: "op", status: "online"},
        {nick: "akash", role: "user", status: "online"},
      ],
    })

    const people = screen.getByRole("complementary", {name: "People here"})
    await waitFor(() => expect(within(people).getByText("akash")).toBeInTheDocument())
    expect(within(people).getByText("mira")).toBeInTheDocument()
  })

  test("applies incremental presence diff events to the user sidebar", async () => {
    mockBootstrapFetch()
    let realtimeHandlers
    const client = fakeRealtimeClient(vi.fn())

    render(
      <IrcpipeApp
        currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}}
        developerOauth={true}
        realtimeClientFactory={({handlers}) => {
          realtimeHandlers = handlers
          return client
        }}
      />
    )

    expect(await screen.findByRole("heading", {name: "#testing"})).toBeInTheDocument()

    realtimeHandlers.onPresenceSync({
      buffer_id: "channel:7",
      users: [{nick: "mira", role: "op", status: "online"}],
    })
    realtimeHandlers.onPresenceDiff({
      buffer_id: "channel:7",
      diff: {action: "join", user: {nick: "akash", role: "user", status: "online"}},
    })

    const people = screen.getByRole("complementary", {name: "People here"})
    await waitFor(() => expect(within(people).getByText("akash")).toBeInTheDocument())

    realtimeHandlers.onPresenceDiff({buffer_id: "channel:7", diff: {action: "away", nick: "akash", status: "away"}})
    await waitFor(() => expect(within(people).getByText("Away")).toBeInTheDocument())
    expect(within(people).getByText("akash")).toBeInTheDocument()

    realtimeHandlers.onPresenceDiff({buffer_id: "channel:7", diff: {action: "away", nick: "akash", status: "online"}})
    await waitFor(() => expect(within(people).queryByText("Away")).not.toBeInTheDocument())

    realtimeHandlers.onPresenceDiff({buffer_id: "channel:7", diff: {action: "role", nick: "akash", role: "op"}})
    await waitFor(() => expect(within(people).getByText("Mods")).toBeInTheDocument())
    await waitFor(() => expect(within(people).getAllByText("mod")).toHaveLength(2))
    expect(within(people).getByText("akash")).toBeInTheDocument()

    realtimeHandlers.onPresenceDiff({buffer_id: "channel:7", diff: {action: "role", nick: "akash", role: "user"}})
    await waitFor(() => expect(within(people).getAllByText("mod")).toHaveLength(1))

    realtimeHandlers.onPresenceDiff({buffer_id: "channel:7", diff: {action: "nick", old_nick: "akash", new_nick: "ak"}})
    await waitFor(() => expect(within(people).getByText("ak")).toBeInTheDocument())

    realtimeHandlers.onPresenceDiff({buffer_id: "channel:7", diff: {action: "part", nick: "ak"}})
    await waitFor(() => expect(within(people).queryByText("ak")).not.toBeInTheDocument())
  })

  test("removes a channel buffer after a realtime leave event", async () => {
    mockBootstrapFetch()
    let realtimeHandlers
    const client = fakeRealtimeClient(vi.fn())

    render(
      <IrcpipeApp
        currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}}
        developerOauth={true}
        realtimeClientFactory={({handlers}) => {
          realtimeHandlers = handlers
          return client
        }}
      />
    )

    expect(await screen.findByRole("heading", {name: "#testing"})).toBeInTheDocument()

    realtimeHandlers.onBufferLeft({
      type: "buffer:left",
      buffer_id: "channel:7",
      server_connection_id: 42,
      channel_membership_id: 7,
    })

    expect(await screen.findByRole("heading", {name: "127.0.0.1", level: 2})).toBeInTheDocument()
    expect(screen.queryByRole("button", {name: /#testing/})).not.toBeInTheDocument()
    expect(screen.queryByRole("complementary", {name: "People here"})).not.toBeInTheDocument()
  })

  test("removes a server after a realtime server buffer leave event", async () => {
    mockBootstrapFetch()
    let realtimeHandlers
    const client = fakeRealtimeClient(vi.fn())

    render(
      <IrcpipeApp
        currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}}
        developerOauth={true}
        realtimeClientFactory={({handlers}) => {
          realtimeHandlers = handlers
          return client
        }}
      />
    )

    expect(await screen.findByRole("heading", {name: "#testing"})).toBeInTheDocument()

    realtimeHandlers.onBufferLeft({
      type: "buffer:left",
      buffer_id: "server:42",
      server_connection_id: 42,
      channel_membership_id: null,
    })

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
      <IrcpipeApp
        currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}}
        developerOauth={true}
        realtimeClientFactory={({handlers}) => {
          realtimeHandlers = handlers
          return client
        }}
      />
    )

    expect(await screen.findByRole("heading", {name: "#testing"})).toBeInTheDocument()

    realtimeHandlers.onBufferJoined({
      type: "buffer:joined",
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
    })

    await user.click(await screen.findByRole("button", {name: /^#phoenix$/i}))

    expect(screen.getByRole("heading", {name: "#phoenix"})).toBeInTheDocument()
  })

  test("renders realtime server buffer messages", async () => {
    const user = userEvent.setup()
    mockBootstrapFetch()
    let realtimeHandlers
    const client = fakeRealtimeClient(vi.fn())

    render(
      <IrcpipeApp
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

    realtimeHandlers.onBufferMessage({
      type: "buffer:message",
      buffer_id: "server:42",
      id: 204,
      nick: "127.0.0.1",
      body: "MOTD starts here",
      kind: "notice",
      occurred_at: "2026-05-13T10:03:00Z",
    })

    expect(await screen.findByText("MOTD starts here")).toBeInTheDocument()
  })

  test("shows a new message affordance while reading older chat", async () => {
    const user = userEvent.setup()
    mockBootstrapFetch()
    let realtimeHandlers
    const client = fakeRealtimeClient(vi.fn())

    render(
      <IrcpipeApp
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

    realtimeHandlers.onBufferMessage({
      type: "buffer:message",
      buffer_id: "channel:7",
      id: 205,
      nick: "akash",
      body: "new while reading",
      kind: "message",
      occurred_at: "2026-05-13T10:04:00Z",
    })

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
      role: "user",
      status: "online",
    }))

    render(
      <IrcpipeApp
        currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}}
        developerOauth={true}
        realtimeClientFactory={({handlers}) => {
          realtimeHandlers = handlers
          return client
        }}
      />
    )

    expect(await screen.findByRole("heading", {name: "#testing"})).toBeInTheDocument()

    realtimeHandlers.onPresenceSync({buffer_id: "channel:7", users: manyUsers})

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
      render(<IrcpipeApp currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}} developerOauth={true} />)

      expect(await screen.findByRole("heading", {name: "#testing"})).toBeInTheDocument()
      expect(requestPermission).not.toHaveBeenCalled()

      await user.click(screen.getByLabelText("Set up mention notifications for #testing"))

      expect(requestPermission).toHaveBeenCalledTimes(1)
      expect(await screen.findByLabelText("Mute mention notifications for #testing")).toHaveClass("text-emerald-950")
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
    const installationStorageKey = "ircpipe.notification-installation"
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
      render(<IrcpipeApp currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}} developerOauth={true} />)

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
    const installationStorageKey = "ircpipe.notification-installation"
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
        <IrcpipeApp
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

    render(<IrcpipeApp currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}} developerOauth={true} />)

    await user.click(screen.getByLabelText("Join another server"))
    await user.clear(screen.getByLabelText("Server"))
    await user.type(screen.getByLabelText("Server"), "irc.example.net")
    await user.clear(screen.getByLabelText("Auto-join channels"))
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

    render(<IrcpipeApp currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}} developerOauth={true} />)

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
      <IrcpipeApp
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
        <IrcpipeApp
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

      realtimeHandlers.onBufferLeft({
        type: "buffer:left",
        buffer_id: "channel:7",
        server_connection_id: 42,
        channel_membership_id: 7,
      })

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

    render(
      <IrcpipeApp
        currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}}
        developerOauth={true}
        realtimeClientFactory={() => client}
      />
    )

    expect(await screen.findByRole("heading", {name: "#testing"})).toBeInTheDocument()

    await waitFor(() => expect(push).toHaveBeenCalledWith("buffer:read", {buffer_id: "channel:7"}))
    await waitFor(() => expect(screen.queryByText("3")).not.toBeInTheDocument())
  })

  test("marks visible active channel read after receiving a realtime message", async () => {
    mockBootstrapFetch({channelMentionCount: 0, channelUnreadCount: 0})
    const push = vi.fn(() => Promise.resolve({ok: true}))
    let realtimeHandlers
    const client = fakeRealtimeClient(push)

    render(
      <IrcpipeApp
        currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}}
        developerOauth={true}
        realtimeClientFactory={({handlers}) => {
          realtimeHandlers = handlers
          return client
        }}
      />
    )

    expect(await screen.findByRole("heading", {name: "#testing"})).toBeInTheDocument()

    realtimeHandlers.onBufferMessage({
      id: 201,
      buffer_id: "channel:7",
      nick: "akash",
      body: "hello mira",
      kind: "message",
      mentioned: true,
      occurred_at: "2026-05-13T10:01:00Z",
    })

    await waitFor(() => expect(push).toHaveBeenCalledWith("buffer:read", {buffer_id: "channel:7"}))
  })

  test("uses the server action menu for reconnect and disconnect actions", async () => {
    const user = userEvent.setup()
    mockBootstrapFetch()
    const push = vi.fn((event) => {
      if (event === "server:reconnect") {
        return Promise.resolve({type: "server:status", server_connection_id: 42, status: "connecting"})
      }

      return Promise.resolve({type: "server:status", server_connection_id: 42, status: "disconnected"})
    })
    const client = fakeRealtimeClient(push)

    render(
      <IrcpipeApp
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

    render(<IrcpipeApp currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}} developerOauth={true} />)

    expect(await screen.findByRole("heading", {name: "#testing"})).toBeInTheDocument()

    await user.click(screen.getByRole("button", {name: "Server actions for local"}))
    await user.click(screen.getByRole("menuitem", {name: "Edit connection"}))

    const dialog = screen.getByRole("dialog", {name: "Edit server"})
    await user.clear(within(dialog).getByLabelText("Server"))
    await user.type(within(dialog).getByLabelText("Server"), "irc.edited.test")
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
            connection: {name: "local", host: "irc.edited.test", port: 6697, use_tls: true, nickname: "mira2"},
          }),
        })
      )
    )
    const nav = screen.getByRole("navigation", {name: "Joined topics"})
    expect(within(nav).getByText("edited")).toBeInTheDocument()
    expect(screen.getAllByText("on irc.edited.test").length).toBeGreaterThan(0)
  })

  test("confirms leaving a server from the server action menu", async () => {
    const user = userEvent.setup()
    mockBootstrapFetch()

    render(<IrcpipeApp currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}} developerOauth={true} />)

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

  test("browses, filters, and joins channels from a server directory", async () => {
    const user = userEvent.setup()
    mockBootstrapFetch()
    let realtimeHandlers
    const push = vi.fn((event) => {
      if (event === "server:list") {
        return Promise.resolve({
          directory: {
            server_connection_id: 42,
            server_name: "local",
            server_host: "127.0.0.1",
            channels: [
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
      <IrcpipeApp
        currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}}
        developerOauth={true}
        realtimeClientFactory={({handlers}) => {
          realtimeHandlers = handlers
          return client
        }}
      />
    )

    await user.click(await screen.findByRole("button", {name: "Browse channels on local"}))

    expect(push).toHaveBeenCalledWith("server:list", {server_connection_id: 42})
    expect(await screen.findByRole("heading", {name: "Channels on local"})).toBeInTheDocument()
    expect(screen.getByText("Phoenix, OTP, and releases")).toBeInTheDocument()
    expect(screen.getByText("42 people")).toBeInTheDocument()

    await user.type(screen.getByLabelText("Search this server"), "quiet")
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

    realtimeHandlers.onBufferLeft({
      type: "buffer:left",
      buffer_id: "channel:12",
      server_connection_id: 42,
      channel_membership_id: 12,
    })

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
      <IrcpipeApp
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

    realtimeHandlers.onBufferLeft({
      type: "buffer:left",
      buffer_id: "channel:12",
      server_connection_id: 42,
      channel_membership_id: 12,
    })

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
      <IrcpipeApp
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
    realtimeHandlers.onBufferLeft({type: "buffer:left", buffer_id: "channel:12", server_connection_id: 42})
    resolveFirstJoin(joinResponse(12, "#elixir"))
    expect(await screen.findByText(/Could not join #elixir/)).toBeInTheDocument()

    await user.click(within(row).getByRole("button", {name: "Join"}))
    realtimeHandlers.onBufferLeft({type: "buffer:left", buffer_id: "channel:7", server_connection_id: 42})
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
      <IrcpipeApp
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
      <IrcpipeApp
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

  test("does not reopen a directory after navigating away from a pending /list command", async () => {
    const user = userEvent.setup()
    mockBootstrapFetch()
    let resolveCommand
    const push = vi.fn((event) => {
      if (event === "command:run") return new Promise((resolve) => { resolveCommand = resolve })
      return Promise.resolve({ok: true})
    })
    const client = fakeRealtimeClient(push)
    let realtimeHandlers

    render(
      <IrcpipeApp
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
    await user.click(screen.getByRole("button", {name: "local"}))

    resolveCommand({
      command: {name: "list", args: []},
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

  test("opens the active server directory from the /list command", async () => {
    const user = userEvent.setup()
    mockBootstrapFetch()
    const push = vi.fn((event) => {
      if (event === "command:run") {
        return Promise.resolve({
          command: {name: "list", args: []},
          directory: {
            server_connection_id: 42,
            server_name: "local",
            server_host: "127.0.0.1",
            channels: [{channel: "#elixir", users: 42, topic: "Phoenix, OTP, and releases"}],
          },
        })
      }

      return Promise.resolve({ok: true})
    })
    const client = fakeRealtimeClient(push)
    let realtimeHandlers

    render(
      <IrcpipeApp
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

    expect(push).toHaveBeenCalledWith(
      "command:run",
      expect.objectContaining({command_id: expect.any(String), input: "/list", buffer_id: "channel:7"})
    )
    expect(await screen.findByRole("heading", {name: "Channels on local"})).toBeInTheDocument()
    expect(screen.getByText("#elixir")).toBeInTheDocument()
  })

  test("shows slash command suggestions from the chat composer", async () => {
    const user = userEvent.setup()
    mockBootstrapFetch()

    render(<IrcpipeApp currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}} developerOauth={true} />)

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
      <IrcpipeApp
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
      <IrcpipeApp
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
      <IrcpipeApp
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

    render(<IrcpipeApp currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}} developerOauth={true} />)

    await user.type(screen.getByLabelText("Message composer"), "hello /join")

    expect(screen.queryByRole("listbox", {name: "Slash command suggestions"})).not.toBeInTheDocument()
  })

  test("keeps signed-in users on the public landing page unless they open chat", async () => {
    mockTopicsFetch()

    render(
      <IrcpipeApp
        appMode="landing"
        currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}}
        developerOauth={true}
      />
    )

    expect(await screen.findByRole("heading", {name: "Community chat"})).toBeInTheDocument()
    expect(screen.getByRole("link", {name: "Open chat"})).toHaveAttribute("href", "/chat")
    expect(screen.queryByRole("navigation", {name: "Joined topics"})).not.toBeInTheDocument()
  })

})
