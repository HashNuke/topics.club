import {describe, expect, test} from "vitest"
import {
  appendTimelineMessage,
  chatReducer,
  emptyChatState,
  hydrateBootstrap,
  latestBackendMessageId,
  mergeNewerMessages,
  mergeOlderMessages,
  normalizeChannel,
  normalizeMessage,
  normalizeTopic,
} from "./chat_store.ts"

const bootstrap = {
  notification_state: "granted",
  connections: [{id: 1, name: "local", status: "connected"}],
  buffers: [
    {
      buffer_id: "server:1",
      buffer_type: "server",
      server_connection_id: 1,
      title: "127.0.0.1",
      status: "connected",
      unread_count: 0,
      mention_count: 0,
    },
    {
      buffer_id: "channel:2",
      buffer_type: "channel",
      server_connection_id: 1,
      title: "#elixir",
      status: "connected",
      unread_count: 2,
      mention_count: 1,
    },
  ],
  active_buffer_id: "channel:2",
  messages_by_buffer: {"channel:2": [{id: 10, body: "hello", buffer_id: "channel:2"}]},
  users_by_buffer: {"channel:2": [{nick: "mira", role: "op"}]},
}

describe("chat store", () => {
  test("hydrates bootstrap data into the shared state shape", () => {
    expect(hydrateBootstrap(bootstrap)).toMatchObject({
      connections: bootstrap.connections,
      buffers: bootstrap.buffers,
      activeBufferId: "channel:2",
      messagesByBuffer: bootstrap.messages_by_buffer,
      usersByBuffer: bootstrap.users_by_buffer,
      unreadByBuffer: {
        "server:1": {unread_count: 0, mention_count: 0},
        "channel:2": {unread_count: 2, mention_count: 1},
      },
      connectionHealth: "connected",
      notificationState: "granted",
    })
  })

  test("appends inactive buffer messages and increments unread counters", () => {
    const state = {...hydrateBootstrap(bootstrap), activeBufferId: "server:1"}

    const next = chatReducer(state, {
      type: "buffer:message",
      message: {id: 11, body: "mira: ping", buffer_id: "channel:2", mentioned: true},
    })

    expect(next.messagesByBuffer["channel:2"].map((message) => message.id)).toEqual([10, 11])
    expect(next.unreadByBuffer["channel:2"]).toEqual({unread_count: 3, mention_count: 2})
  })

  test("keeps active buffer unread counters unchanged when messages arrive", () => {
    const state = hydrateBootstrap(bootstrap)

    const next = chatReducer(state, {
      type: "buffer:message",
      message: {id: 11, body: "active", buffer_id: "channel:2", mentioned: true},
    })

    expect(next.unreadByBuffer["channel:2"]).toEqual({unread_count: 2, mention_count: 1})
  })

  test("resets read counters and applies presence sync", () => {
    const read = chatReducer(hydrateBootstrap(bootstrap), {type: "buffer:read", buffer_id: "channel:2"})
    const synced = chatReducer(read, {
      type: "presence:sync",
      buffer_id: "channel:2",
      users: [{nick: "akash", role: "user"}],
    })

    expect(synced.unreadByBuffer["channel:2"]).toEqual({unread_count: 0, mention_count: 0})
    expect(synced.buffers.find((buffer) => buffer.buffer_id === "channel:2")).toMatchObject({
      unread_count: 0,
      mention_count: 0,
    })
    expect(synced.usersByBuffer["channel:2"]).toEqual([{nick: "akash", role: "user"}])
  })

  test("applies presence diffs through the reducer", () => {
    const joined = chatReducer(hydrateBootstrap(bootstrap), {
      type: "presence:diff",
      buffer_id: "channel:2",
      diff: {action: "join", user: {nick: "akash", role: "user"}},
    })
    const renamed = chatReducer(joined, {
      type: "presence:diff",
      buffer_id: "channel:2",
      diff: {action: "nick", old_nick: "mira", new_nick: "mira_"},
    })
    const promoted = chatReducer(renamed, {
      type: "presence:diff",
      buffer_id: "channel:2",
      diff: {action: "role", nick: "akash", role: "voice"},
    })
    const parted = chatReducer(promoted, {
      type: "presence:diff",
      buffer_id: "channel:2",
      diff: {action: "part", nick: "mira_"},
    })

    expect(parted.usersByBuffer["channel:2"]).toEqual([{nick: "akash", role: "voice"}])
  })

  test("tracks connection health and server status", () => {
    const state = chatReducer(emptyChatState, {type: "bootstrap:loaded", bootstrap})
    const reconnecting = chatReducer(state, {type: "connection:health", status: "reconnecting"})
    const errored = chatReducer(reconnecting, {
      type: "server:status",
      server_connection_id: 1,
      status: "errored",
    })

    expect(errored.connectionHealth).toBe("reconnecting")
    expect(errored.connections[0].status).toBe("errored")
    expect(errored.buffers.map((buffer) => buffer.status)).toEqual(["errored", "errored"])
  })

  test("preserves IRC channel type prefixes", () => {
    expect(normalizeChannel("elixir")).toBe("#elixir")
    expect(normalizeChannel("#elixir")).toBe("#elixir")
    expect(normalizeChannel("&local")).toBe("&local")
    expect(normalizeChannel("+modeless")).toBe("+modeless")
    expect(normalizeChannel("!safe")).toBe("!safe")
  })

  test("normalizes topic and message payloads outside UI components", () => {
    expect(normalizeTopic({server_host: "127.0.0.1", channel: "elixir"})).toMatchObject({
      id: "127.0.0.1-elixir",
      channel: "#elixir",
      name: "#elixir",
    })

    expect(normalizeMessage({id: 1, occurred_at: "2026-05-13T10:00:00Z"})).toMatchObject({
      id: 1,
      occurredAt: "2026-05-13T10:00:00Z",
    })
  })

  test("deduplicates older, newer, and appended timeline messages", () => {
    const current = [
      {id: 2, body: "two"},
      {id: 3, body: "three"},
    ]

    expect(mergeOlderMessages([{id: 1, body: "one"}, {id: 2, body: "two"}], current).map((message) => message.id)).toEqual([
      1,
      2,
      3,
    ])
    expect(mergeNewerMessages(current, [{id: 3, body: "three updated", metadata: {command_status: "completed"}}, {id: 4, body: "four"}])).toEqual([
      {id: 2, body: "two"},
      {id: 3, body: "three updated", metadata: {command_status: "completed"}},
      {id: 4, body: "four"},
    ])
    expect(appendTimelineMessage(current, {id: 3, body: "three"}, false).map((message) => message.id)).toEqual([2, 3])
  })

  test("keeps merged messages ordered and tracks only persisted cursors", () => {
    const current = [
      {id: 10, body: "ten", occurredAt: "2026-05-13T10:10:00Z"},
      {id: "client-1", body: "pending", occurredAt: "2026-05-13T10:12:00Z"},
    ]

    const merged = mergeNewerMessages(current, [
      {id: 11, body: "eleven", occurredAt: "2026-05-13T10:11:00Z"},
      {id: 10, body: "ten duplicate", occurredAt: "2026-05-13T10:10:00Z"},
    ])

    expect(merged.map((message) => message.id)).toEqual([10, 11, "client-1"])
    expect(merged.find((message) => message.id === 10)?.body).toBe("ten duplicate")
    expect(latestBackendMessageId(merged)).toBe(11)
  })

  test("does not regress a terminal command row with a stale tail snapshot", () => {
    const completed = {
      id: 12,
      kind: "command",
      body: "WHOIS mira",
      metadata: {command_status: "completed"},
    }
    const staleSent = {
      ...completed,
      metadata: {command_status: "sent"},
    }

    expect(mergeNewerMessages([completed], [staleSent])).toEqual([completed])
  })

  test("repairs a locally sent command from an overlapping older history page", () => {
    const sent = {
      id: 12,
      kind: "command",
      body: "LIST",
      metadata: {command_status: "sent"},
    }
    const completed = {...sent, metadata: {command_status: "completed"}}

    expect(mergeOlderMessages([completed], [sent])).toEqual([completed])
  })
})
