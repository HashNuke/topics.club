import {describe, expect, test} from "vitest"
import {buildBootstrapState} from "./bootstrap_state.ts"

describe("buildBootstrapState", () => {
  test("normalizes connections, buffers, messages, and active channel", () => {
    const state = buildBootstrapState({
      active_buffer_id: "channel:2",
      buffers: [{buffer_id: "channel:2", buffer_type: "channel", channel_membership_id: 2, server_connection_id: 1, title: "#elixir", subtitle: "Welcome", unread_count: 2, mention_count: 1}],
      command_catalog: [{name: "join"}],
      connections: [{id: 1, name: "local", host: "127.0.0.1", port: 6667, use_tls: false, nickname: "mira", status: "connected"}],
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
    expect(buildBootstrapState({buffers: [], connections: [], active_buffer_id: "server:4"})).toMatchObject({
      activeServerId: "server:4",
      view: "server",
    })
    expect(buildBootstrapState({connections: []})).toBeNull()
  })
})
