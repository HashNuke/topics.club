import {describe, expect, test} from "vitest"
import {buildBootstrapState} from "./bootstrap_state.ts"

const push = {
  configured: false,
  vapid_public_key: null,
  session_generation: "test-session",
  session_installation_id: null,
  session_registration_confirmed: false,
} as const
const user = {id: 1, email: "mira@example.com"}

function directBuffer(id: number, title: string, overrides = {}) {
  return {
    buffer_id: `direct:${id}`,
    buffer_type: "direct_message",
    server_connection_id: 1,
    direct_message_thread_id: id,
    direct_message_revision: 1,
    title,
    subtitle: "on irc.example.test",
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

describe("buildBootstrapState", () => {
  test("normalizes connections, buffers, messages, and active channel", () => {
    const state = buildBootstrapState({
      user,
      active_buffer_id: "channel:2",
      buffers: [{buffer_id: "channel:2", buffer_type: "channel", channel_membership_id: 2, server_connection_id: 1, title: "#elixir", subtitle: "Welcome", unread_count: 2, mention_count: 1, mention_notifications_enabled: true, notification_preference_revision: 0}],
      command_catalog: [{name: "join"}],
      connections: [{id: 1, name: "local", host: "127.0.0.1", port: 6667, use_tls: false, nickname: "mira", status: "connected", mention_notifications_enabled: true, notification_preference_revision: 0}],
      direct_message_tombstones: [],
      message_cursors_by_buffer: {"channel:2": 9},
      messages_by_buffer: {"server:1": [{id: 8, body: "ready"}], "channel:2": [{id: 9, body: "hello", occurred_at: "2026-08-26T00:00:00Z"}]},
      push,
      topics: [{id: 3, channel: "elixir", server_host: "127.0.0.1"}],
      users_by_buffer: {"channel:2": [{nick: "mira"}]},
    })

    expect(state).toMatchObject({
      activeChannelId: "channel:2",
      activeServerId: "server:1",
      commandCatalog: [{name: "join"}],
      cursorsByBuffer: {"channel:2": 9},
      usersByChannel: {"channel:2": [{nick: "mira"}]},
    })
    expect(state.connections[0].channels[0]).toMatchObject({id: "channel:2", channel: "#elixir"})
    expect(state.messagesByChannel["channel:2"][0]).toMatchObject({id: 9, occurredAt: "2026-08-26T00:00:00Z"})
    expect(state.messagesByServer["server:1"][0]).toMatchObject({id: 8})
    expect(state.topics[0]).toMatchObject({id: 3, channel: "#elixir"})
  })

  test("selects an active server and rejects incomplete payloads", () => {
    expect(buildBootstrapState({user, buffers: [], connections: [], direct_message_tombstones: [], active_buffer_id: "server:4", push})).toMatchObject({
      activeServerId: null,
      view: null,
    })
    expect(buildBootstrapState({user, connections: []})).toBeNull()
  })

  test("accepts the authoritative bootstrap DM shape and restores the direct buffer", () => {
    const state = buildBootstrapState({
      user,
      active_buffer_id: "direct:9",
      connections: [{id: 1, name: "local", host: "irc.example.test", mention_notifications_enabled: true, notification_preference_revision: 0}],
      direct_message_tombstones: [],
      buffers: [
        {buffer_id: "server:1", buffer_type: "server", server_connection_id: 1, title: "irc.example.test", mention_notifications_enabled: true, notification_preference_revision: 0},
        {buffer_id: "channel:3", buffer_type: "channel", server_connection_id: 1, channel_membership_id: 3, title: "#zulu", mention_notifications_enabled: true, notification_preference_revision: 0},
        directBuffer(9, "Zed", {unread_count: 2}),
        directBuffer(8, "akash", {blocked: true}),
        {buffer_id: "channel:2", buffer_type: "channel", server_connection_id: 1, channel_membership_id: 2, title: "#alpha", mention_notifications_enabled: true, notification_preference_revision: 0},
      ],
      messages_by_buffer: {"direct:9": [{id: 21, nick: "Zed", body: "ping"}]},
      push,
    })

    expect(state).toMatchObject({
      activeChannelId: "direct:9",
      activeServerId: "server:1",
      view: "chat",
    })
    expect(state.connections[0].channels.map((item) => item.id)).toEqual([
      "direct:8",
      "direct:9",
      "channel:2",
      "channel:3",
    ])
    expect(state.connections[0].channels[0]).toMatchObject({
      buffer_type: "direct_message",
      direct_message_thread_id: 8,
      channel: "akash",
      topic: "on irc.example.test",
      account: null,
      hostmask: null,
      closed_at: null,
      blocked: true,
    })
    expect(state.messagesByChannel["direct:9"][0]).toMatchObject({id: 21, body: "ping"})
  })

  test("drops an open direct-message record shadowed by an equal or newer tombstone", () => {
    const state = buildBootstrapState({
      user,
      active_buffer_id: "direct:9",
      connections: [{id: 1, host: "irc.example.test", mention_notifications_enabled: true, notification_preference_revision: 0}],
      buffers: [
        {buffer_id: "server:1", buffer_type: "server", server_connection_id: 1, title: "irc.example.test", mention_notifications_enabled: true, notification_preference_revision: 0},
        directBuffer(9, "Zed"),
      ],
      direct_message_tombstones: [{buffer_id: "direct:9", server_connection_id: 1, direct_message_thread_id: 9, revision: 2}],
      push,
    })

    expect(state.connections[0].channels).toEqual([])
    expect(state.activeChannelId).toBeNull()
  })

  test("rejects notification and direct-message records missing authoritative protocol fields", () => {
    expect(buildBootstrapState({
      user,
      buffers: [],
      connections: [{id: 1, host: "irc.example.test"}],
      direct_message_tombstones: [],
      push,
    })).toBeNull()

    expect(buildBootstrapState({
      user,
      buffers: [{buffer_id: "direct:9", buffer_type: "direct_message", server_connection_id: 1, title: "Zed", direct_message_revision: 1}],
      connections: [{id: 1, host: "irc.example.test", mention_notifications_enabled: true, notification_preference_revision: 0}],
      direct_message_tombstones: [],
      push,
    })).toBeNull()
  })
})
