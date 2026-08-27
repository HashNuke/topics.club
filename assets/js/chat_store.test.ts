import {describe, expect, test} from "vitest"
import {
  applyUserDiff,
  appendTimelineMessage,
  latestBackendMessageId,
  mergeNewerMessages,
  mergeOlderMessages,
  normalizeChannel,
  normalizeMessage,
  normalizeTopic,
} from "./chat_store.ts"

describe("chat store", () => {
  test("applies presence diffs by canonical IRC nick key", () => {
    const users = [
      {nick: "{mira}", nick_key: "{mira}", role: "user"},
      {nick: "mi^ra", nick_key: "mi^ra", role: "user"},
      {nick: "mi~ra", nick_key: "mi~ra", role: "user"},
    ]

    const joined = applyUserDiff(users, {
      action: "join",
      user: {nick: "[MIRA]", nick_key: "{mira}", role: "op"},
    })

    expect(joined).toHaveLength(3)
    expect(joined[0]).toMatchObject({nick: "[MIRA]", nick_key: "{mira}", role: "op"})

    const away = applyUserDiff(joined, {
      action: "away",
      nick: "[mira]",
      nick_key: "{mira}",
      status: "away",
    })

    expect(away[0]).toMatchObject({nick: "[MIRA]", nick_key: "{mira}", status: "away"})

    const renamed = applyUserDiff(away, {
      action: "nick",
      old_nick: "[mira]",
      old_nick_key: "{mira}",
      new_nick: "Other",
      new_nick_key: "other",
    })

    expect(renamed[0]).toMatchObject({nick: "Other", nick_key: "other"})

    const parted = applyUserDiff(renamed, {
      action: "part",
      nick: "OTHER",
      nick_key: "other",
    })

    expect(parted.map((user) => user.nick_key)).toEqual(["mi^ra", "mi~ra"])
  })

  test("preserves IRC channel type prefixes", () => {
    expect(normalizeChannel("elixir")).toBe("#elixir")
    expect(normalizeChannel("#elixir")).toBe("#elixir")
    expect(normalizeChannel("&local")).toBe("&local")
    expect(normalizeChannel("+modeless")).toBe("+modeless")
    expect(normalizeChannel("!safe")).toBe("!safe")
  })

  test("normalizes topic and message payloads outside UI components", () => {
    const topic = normalizeTopic({
      id: 3,
      channel: "elixir",
      name: "elixir",
      description: "Elixir discussion",
      server_host: "127.0.0.1",
      server_port: 6697,
      use_tls: true,
    })

    expect(topic).toMatchObject({
      id: 3,
      channel: "#elixir",
      name: "#elixir",
    })
    expect(topic).not.toHaveProperty("vibe")

    const topicWithExtras = {
      id: 4,
      channel: "#phoenix",
      name: "#phoenix",
      description: "Phoenix discussion",
      server_host: "127.0.0.1",
      server_port: 6697,
      use_tls: true,
      members: {},
      vibe: {},
    }
    const topicWithWireExtras = normalizeTopic(topicWithExtras)
    expect(topicWithWireExtras).not.toHaveProperty("members")
    expect(topicWithWireExtras).not.toHaveProperty("vibe")

    expect(normalizeMessage({
      type: "buffer:message",
      version: 1,
      id: 1,
      event_id: "message:1",
      buffer_id: "channel:7",
      server_connection_id: 42,
      channel_membership_id: 7,
      direct_message_thread_id: null,
      occurred_at: "2026-05-13T10:00:00Z",
      nick: "mira",
      hostmask: null,
      sender_role: null,
      service: null,
      body: "hello",
      kind: "message",
      mentioned: false,
      metadata: {},
    })).toMatchObject({
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
