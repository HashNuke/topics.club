import {describe, expect, test} from "vitest"
import {buildBootstrapState} from "./bootstrap_state.ts"

describe("buildBootstrapState", () => {
  test("normalizes connections, buffers, messages, and active channel", () => {
    const state = buildBootstrapState({
      active_buffer_id: "channel:2",
      buffers: [{buffer_id: "channel:2", buffer_type: "channel", channel_membership_id: 2, server_connection_id: 1, title: "#elixir", subtitle: "Welcome", unread_count: 2, mention_count: 1}],
      command_catalog: [{name: "join"}],
      connections: [{id: 1, name: "local", host: "127.0.0.1", port: 6667, use_tls: false, nickname: "mira", status: "connected"}],
      direct_message_tombstones: [],
      message_cursors_by_buffer: {"channel:2": 9},
      messages_by_buffer: {"server:1": [{id: 8, body: "ready"}], "channel:2": [{id: 9, body: "hello", occurred_at: "2026-08-26T00:00:00Z"}]},
      notification_state: "granted",
      topics: [{id: 3, channel: "elixir", server_host: "127.0.0.1"}],
      users_by_buffer: {"channel:2": [{nick: "mira"}]},
    })

    expect(state).toMatchObject({
      activeChannelId: "channel:2",
      activeServerId: "server:1",
      commandCatalog: [{name: "join"}],
      cursorsByBuffer: {"channel:2": 9},
      notificationState: "granted",
      usersByChannel: {"channel:2": [{nick: "mira"}]},
    })
    expect(state.connections[0].channels[0]).toMatchObject({id: "channel:2", channel: "#elixir"})
    expect(state.messagesByChannel["channel:2"][0]).toMatchObject({id: 9, occurredAt: "2026-08-26T00:00:00Z"})
    expect(state.messagesByServer["server:1"][0]).toMatchObject({id: 8})
    expect(state.topics[0]).toMatchObject({id: 3, channel: "#elixir"})
  })

  test("selects an active server and rejects incomplete payloads", () => {
    expect(buildBootstrapState({buffers: [], connections: [], direct_message_tombstones: [], active_buffer_id: "server:4"})).toMatchObject({
      activeServerId: "server:4",
      view: "server",
    })
    expect(buildBootstrapState({connections: []})).toBeNull()
  })

  test("hydrates direct messages before alphabetized channels and restores a direct buffer", () => {
    const state = buildBootstrapState({
      active_buffer_id: "direct:9",
      connections: [{id: 1, name: "local", host: "irc.example.test"}],
      direct_message_tombstones: [],
      buffers: [
        {buffer_id: "server:1", buffer_type: "server", server_connection_id: 1, title: "irc.example.test"},
        {buffer_id: "channel:3", buffer_type: "channel", server_connection_id: 1, channel_membership_id: 3, title: "#zulu"},
        {buffer_id: "direct:9", buffer_type: "direct_message", server_connection_id: 1, direct_message_thread_id: 9, title: "Zed", unread_count: 2, blocked: false},
        {buffer_id: "direct:8", buffer_type: "direct_message", server_connection_id: 1, direct_message_thread_id: 8, title: "akash", unread_count: 0, blocked: true},
        {buffer_id: "channel:2", buffer_type: "channel", server_connection_id: 1, channel_membership_id: 2, title: "#alpha"},
      ],
      messages_by_buffer: {"direct:9": [{id: 21, nick: "Zed", body: "ping"}]},
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
      blocked: true,
    })
    expect(state.messagesByChannel["direct:9"][0]).toMatchObject({id: 21, body: "ping"})
  })
})
