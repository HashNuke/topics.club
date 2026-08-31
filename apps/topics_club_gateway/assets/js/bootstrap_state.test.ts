import {describe, expect, test} from "vitest"
import {buildBootstrapState} from "./bootstrap_state.ts"
import type {CommandCatalogEntry, TopicInput} from "./types.ts"

const push = {
  configured: false,
  vapid_public_key: null,
  session_generation: "test-session",
  session_installation_id: null,
  session_registration_confirmed: false,
} as const
const user = {id: 1, email: "mira@example.com"}
const commandCatalog: CommandCatalogEntry[] = [{
  name: "/join",
  usage: "/join #channel",
  description: "Join a channel",
  required_permission: "user",
  contexts: ["server", "channel", "direct"],
  availability: "enabled",
  examples: ["/join #elixir"],
}]
const topics: TopicInput[] = [{
  id: 3,
  channel: "#elixir",
  name: "#elixir",
  description: "Elixir discussion",
  server_host: "127.0.0.1",
  server_port: 6697,
  use_tls: true,
}]
const protocolCatalogs = {command_catalog: commandCatalog, topics}

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

function message(bufferId: string, id: number, body: string, overrides = {}) {
  const [, rawId] = bufferId.split(":")
  const owningId = Number(rawId)

  return {
    type: "buffer:message",
    version: 1,
    event_id: `message:${id}`,
    id,
    buffer_id: bufferId,
    server_connection_id: 1,
    channel_membership_id: bufferId.startsWith("channel:") ? owningId : null,
    direct_message_thread_id: bufferId.startsWith("direct:") ? owningId : null,
    nick: "mira",
    hostmask: null,
    sender_role: null,
    service: null,
    metadata: {},
    body,
    kind: "message",
    mentioned: false,
    occurred_at: "2026-08-26T00:00:00Z",
    ...overrides,
  }
}

describe("buildBootstrapState", () => {
  test("normalizes connections, buffers, messages, and active channel", () => {
    const state = buildBootstrapState({
      ...protocolCatalogs,
      user,
      active_buffer_id: "channel:2",
      buffers: [
        {buffer_id: "server:1", buffer_type: "server", server_connection_id: 1, channel_membership_id: null, title: "127.0.0.1", mention_notifications_enabled: true, notification_preference_revision: 0},
        {buffer_id: "channel:2", buffer_type: "channel", channel_membership_id: 2, server_connection_id: 1, title: "#elixir", subtitle: "Welcome", unread_count: 2, mention_count: 1, mention_notifications_enabled: true, notification_preference_revision: 0},
      ],
      connections: [{id: 1, name: "local", host: "127.0.0.1", port: 6667, use_tls: false, nickname: "mira", status: "connected", mention_notifications_enabled: true, notification_preference_revision: 0}],
      direct_message_tombstones: [],
      message_cursors_by_buffer: {"server:1": 8, "channel:2": 9},
      messages_by_buffer: {
        "server:1": [message("server:1", 8, "ready")],
        "channel:2": [message("channel:2", 9, "hello", {
          occurredAt: "invalid",
          clientMessageId: "wire-client-id",
          pending: true,
          failed: true,
        })],
      },
      push,
      users_by_buffer: {"channel:2": [{nick: "mira", nick_key: "mira"}]},
    })

    expect(state).toMatchObject({
      activeChannelId: "channel:2",
      activeServerId: "server:1",
      commandCatalog,
      cursorsByBuffer: {"server:1": 8, "channel:2": 9},
      usersByChannel: {"channel:2": [{nick: "mira", nick_key: "mira"}]},
    })
    expect(state.connections[0].channels[0]).toMatchObject({id: "channel:2", channel: "#elixir"})
    expect(state.messagesByChannel["channel:2"][0]).toMatchObject({id: 9, occurredAt: "2026-08-26T00:00:00Z"})
    expect(state.messagesByChannel["channel:2"][0]).not.toHaveProperty("clientMessageId")
    expect(state.messagesByChannel["channel:2"][0]).not.toHaveProperty("pending")
    expect(state.messagesByChannel["channel:2"][0]).not.toHaveProperty("failed")
    expect(state.messagesByServer["server:1"][0]).toMatchObject({id: 8})
    expect(state.topics[0]).toMatchObject({id: 3, channel: "#elixir"})
  })

  test("selects an active server and rejects incomplete payloads", () => {
    expect(buildBootstrapState({user, buffers: [], command_catalog: [], connections: [], direct_message_tombstones: [], active_buffer_id: "server:4", message_cursors_by_buffer: {}, messages_by_buffer: {}, push, topics: [], users_by_buffer: {}})).toMatchObject({
      activeServerId: null,
      view: null,
    })
    expect(buildBootstrapState({user, connections: []})).toBeNull()
  })

  test("requires canonical topic and command catalog arrays", () => {
    const base = {
      user,
      buffers: [],
      command_catalog: [],
      connections: [],
      direct_message_tombstones: [],
      message_cursors_by_buffer: {},
      messages_by_buffer: {},
      push,
      topics: [],
      users_by_buffer: {},
    }
    const command = commandCatalog[0]
    const topic = topics[0]

    expect(buildBootstrapState({...base, command_catalog: [command], topics: [topic]})).not.toBeNull()
    expect(buildBootstrapState({...base, command_catalog: [{...command, name: {}}]})).toBeNull()
    expect(buildBootstrapState({...base, command_catalog: [{...command, contexts: ["channel", 7]}]})).toBeNull()
    expect(buildBootstrapState({...base, command_catalog: [{...command, contexts: ["direct"]}]})).not.toBeNull()
    expect(buildBootstrapState({...base, topics: [{...topic, description: {}}]})).toBeNull()
    expect(buildBootstrapState({...base, topics: [{...topic, server_port: 70_000}]})).toBeNull()

    const {command_catalog: _commands, ...withoutCommands} = base
    const {topics: _topics, ...withoutTopics} = base
    expect(buildBootstrapState(withoutCommands)).toBeNull()
    expect(buildBootstrapState(withoutTopics)).toBeNull()
  })

  test("rejects bootstrap presence without canonical channel and nick keys", () => {
    const base = {
      user,
      buffers: [],
      connections: [],
      direct_message_tombstones: [],
      push,
    }

    expect(buildBootstrapState({...base, users_by_buffer: {"channel:2": [{nick: "mira"}]}})).toBeNull()
    expect(
      buildBootstrapState({
        ...base,
        users_by_buffer: {"server:2": [{nick: "mira", nick_key: "mira"}]},
      })
    ).toBeNull()
    expect(buildBootstrapState(base)).toBeNull()

    const channelBase = {
      ...base,
      buffers: [{
        buffer_id: "channel:2",
        buffer_type: "channel",
        channel_membership_id: 2,
        server_connection_id: 1,
        title: "#elixir",
        mention_notifications_enabled: true,
        notification_preference_revision: 0,
      }],
    }

    expect(buildBootstrapState({...channelBase, users_by_buffer: {}})).toBeNull()
    expect(
      buildBootstrapState({
        ...channelBase,
        users_by_buffer: {
          "channel:2": [
            {nick: "[Mira]", nick_key: "{mira}"},
            {nick: "{MIRA}", nick_key: "{mira}"},
          ],
        },
      })
    ).toBeNull()
  })

  test("accepts the authoritative bootstrap DM shape and restores the direct buffer", () => {
    const state = buildBootstrapState({
      ...protocolCatalogs,
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
      messages_by_buffer: {
        "server:1": [],
        "channel:3": [],
        "direct:9": [message("direct:9", 21, "ping", {nick: "Zed"})],
        "direct:8": [],
        "channel:2": [],
      },
      message_cursors_by_buffer: {
        "server:1": null,
        "channel:3": null,
        "direct:9": 21,
        "direct:8": null,
        "channel:2": null,
      },
      push,
      users_by_buffer: {"channel:2": [], "channel:3": []},
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
      ...protocolCatalogs,
      user,
      active_buffer_id: "direct:9",
      connections: [{id: 1, host: "irc.example.test", mention_notifications_enabled: true, notification_preference_revision: 0}],
      buffers: [
        {buffer_id: "server:1", buffer_type: "server", server_connection_id: 1, title: "irc.example.test", mention_notifications_enabled: true, notification_preference_revision: 0},
        directBuffer(9, "Zed"),
      ],
      direct_message_tombstones: [{buffer_id: "direct:9", server_connection_id: 1, direct_message_thread_id: 9, revision: 2}],
      messages_by_buffer: {"server:1": [], "direct:9": []},
      message_cursors_by_buffer: {"server:1": null, "direct:9": null},
      push,
      users_by_buffer: {},
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
      users_by_buffer: {},
    })).toBeNull()

    expect(buildBootstrapState({
      user,
      buffers: [{buffer_id: "direct:9", buffer_type: "direct_message", server_connection_id: 1, title: "Zed", direct_message_revision: 1}],
      connections: [{id: 1, host: "irc.example.test", mention_notifications_enabled: true, notification_preference_revision: 0}],
      direct_message_tombstones: [],
      push,
      users_by_buffer: {},
    })).toBeNull()
  })

  test("rejects malformed and contradictory bootstrap messages", () => {
    const base = {
      ...protocolCatalogs,
      user,
      buffers: [{
        buffer_id: "server:1",
        buffer_type: "server",
        server_connection_id: 1,
        title: "irc.example.test",
        mention_notifications_enabled: true,
        notification_preference_revision: 0,
      }, {
        buffer_id: "channel:2",
        buffer_type: "channel",
        channel_membership_id: 2,
        server_connection_id: 1,
        title: "#elixir",
        mention_notifications_enabled: true,
        notification_preference_revision: 0,
      }],
      connections: [{
        id: 1,
        host: "irc.example.test",
        mention_notifications_enabled: true,
        notification_preference_revision: 0,
      }],
      direct_message_tombstones: [],
      message_cursors_by_buffer: {"server:1": null, "channel:2": 9},
      push,
      users_by_buffer: {"channel:2": []},
    }

    expect(buildBootstrapState({
      ...base,
      messages_by_buffer: {"server:1": [], "channel:2": [{id: 9, nick: "mira", body: "partial"}]},
    })).toBeNull()

    expect(buildBootstrapState({
      ...base,
      messages_by_buffer: {"server:1": [], "channel:2": [{
        type: "buffer:message",
        version: 1,
        event_id: "message:9",
        id: 9,
        buffer_id: "channel:2",
        server_connection_id: 1,
        channel_membership_id: 3,
        direct_message_thread_id: null,
        nick: "mira",
        hostmask: null,
        sender_role: null,
        service: null,
        metadata: {},
        body: "contradictory",
        kind: "message",
        mentioned: false,
        occurred_at: "2026-08-26T00:00:00Z",
      }]},
    })).toBeNull()
  })

  test("requires exact message and cursor coverage for every authoritative buffer", () => {
    const base = {
      ...protocolCatalogs,
      user,
      buffers: [
        {buffer_id: "server:1", buffer_type: "server", server_connection_id: 1, channel_membership_id: null, title: "irc.example.test", mention_notifications_enabled: true, notification_preference_revision: 0},
        {buffer_id: "channel:2", buffer_type: "channel", server_connection_id: 1, channel_membership_id: 2, title: "#elixir", mention_notifications_enabled: true, notification_preference_revision: 0},
      ],
      connections: [{id: 1, host: "irc.example.test", status: "connected", mention_notifications_enabled: true, notification_preference_revision: 0}],
      direct_message_tombstones: [],
      messages_by_buffer: {
        "server:1": [],
        "channel:2": [message("channel:2", 9, "hello")],
      },
      message_cursors_by_buffer: {"server:1": null, "channel:2": 9},
      push,
      users_by_buffer: {"channel:2": []},
    }

    expect(buildBootstrapState(base)).not.toBeNull()
    expect(buildBootstrapState({...base, messages_by_buffer: {"channel:2": base.messages_by_buffer["channel:2"]}})).toBeNull()
    expect(buildBootstrapState({...base, message_cursors_by_buffer: {"channel:2": 9}})).toBeNull()
    expect(buildBootstrapState({...base, message_cursors_by_buffer: {"server:1": null, "channel:2": "invalid"}})).toBeNull()

    const {messages_by_buffer: _messages, ...withoutMessages} = base
    const {message_cursors_by_buffer: _cursors, ...withoutCursors} = base
    expect(buildBootstrapState(withoutMessages)).toBeNull()
    expect(buildBootstrapState(withoutCursors)).toBeNull()
  })

  test("rejects duplicate and orphaned authoritative ownership records", () => {
    const base = {
      ...protocolCatalogs,
      user,
      buffers: [
        {buffer_id: "server:1", buffer_type: "server", server_connection_id: 1, channel_membership_id: null, title: "irc.example.test", mention_notifications_enabled: true, notification_preference_revision: 0},
        {buffer_id: "channel:2", buffer_type: "channel", server_connection_id: 1, channel_membership_id: 2, title: "#elixir", mention_notifications_enabled: true, notification_preference_revision: 0},
      ],
      connections: [{id: 1, host: "irc.example.test", status: "connected", mention_notifications_enabled: true, notification_preference_revision: 0}],
      direct_message_tombstones: [],
      messages_by_buffer: {"server:1": [], "channel:2": [message("channel:2", 9, "hello")]},
      message_cursors_by_buffer: {"server:1": null, "channel:2": 9},
      push,
      users_by_buffer: {"channel:2": []},
    }

    expect(buildBootstrapState({
      ...base,
      connections: [...base.connections, {...base.connections[0]}],
    })).toBeNull()
    expect(buildBootstrapState({
      ...base,
      buffers: [...base.buffers, {...base.buffers[1]}],
    })).toBeNull()
    expect(buildBootstrapState({
      ...base,
      buffers: base.buffers.map((buffer) => buffer.buffer_id === "channel:2" ? {...buffer, server_connection_id: 9} : buffer),
    })).toBeNull()
    expect(buildBootstrapState({
      ...base,
      messages_by_buffer: {
        ...base.messages_by_buffer,
        "channel:2": [message("channel:2", 9, "wrong server", {server_connection_id: 9})],
      },
    })).toBeNull()
    expect(buildBootstrapState({
      ...base,
      direct_message_tombstones: [{buffer_id: "direct:7", server_connection_id: 9, direct_message_thread_id: 7, revision: 1}],
    })).toBeNull()
  })
})
