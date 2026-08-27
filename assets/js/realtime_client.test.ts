import {describe, expect, test, vi} from "vitest"
import {createRealtimeClient} from "./realtime_client.ts"

class FakeSocket {
  constructor(path, options) {
    this.path = path
    this.options = options
    this.connected = false
    this.connectCount = 0
    this.disconnected = false
    this.fakeChannel = new FakeChannel()
    this.lifecycleHandlers = {}
  }

  channel(topic, payload) {
    this.topic = topic
    this.channelPayload = payload
    return this.fakeChannel
  }

  onOpen(callback) {
    this.lifecycleHandlers.open = callback
  }

  onClose(callback) {
    this.lifecycleHandlers.close = callback
  }

  onError(callback) {
    this.lifecycleHandlers.error = callback
  }

  connect() {
    this.connected = true
    this.connectCount += 1
  }

  disconnect(callback) {
    this.disconnected = true
    callback?.()
  }

  connectionState() {
    return this.connected ? "open" : "closed"
  }
}

class FakeChannel {
  constructor() {
    this.handlers = {}
    this.left = false
    this.joinCount = 0
  }

  on(event, callback) {
    this.handlers[event] = callback
  }

  join() {
    if (this.joinCount > 0) throw new Error("channel instances may only join once")
    this.joinCount += 1
    return receiver()
  }

  onError(callback) {
    this.handlers.phx_error = callback
  }

  onClose(callback) {
    this.handlers.phx_close = callback
  }

  push(event, payload, timeout) {
    this.pushed = {event, payload, timeout}
    return receiver({ok: {accepted: true}})
  }

  leave() {
    this.left = true
  }
}

class TimeoutChannel extends FakeChannel {
  push(event, payload, timeout) {
    this.pushed = {event, payload, timeout}
    return receiver({timeout: true})
  }
}

class TimeoutSocket extends FakeSocket {
  constructor(path, options) {
    super(path, options)
    this.fakeChannel = new TimeoutChannel()
  }
}

function receiver(responses = {}) {
  return {
    receive(status, callback) {
      if (responses[status]) callback(responses[status])
      return this
    },
  }
}

function presenceEnvelope(type, payload = {}) {
  return {
    type,
    version: 1,
    event_id: `${type === "presence:sync" ? "presence_sync" : "presence_diff"}:channel:7:1`,
    occurred_at: "2026-08-27T00:00:00Z",
    buffer_id: "channel:7",
    server_connection_id: 42,
    channel_membership_id: 7,
    ...payload,
  }
}

const occurredAt = "2026-08-27T00:00:00Z"

function connection(overrides = {}) {
  return {
    id: 42,
    host: "irc.example.test",
    mention_notifications_enabled: true,
    notification_preference_revision: 0,
    ...overrides,
  }
}

function channelBuffer(overrides = {}) {
  return {
    buffer_id: "channel:7",
    buffer_type: "channel",
    server_connection_id: 42,
    channel_membership_id: 7,
    title: "#elixir",
    mention_notifications_enabled: true,
    notification_preference_revision: 0,
    ...overrides,
  }
}

function messageEnvelope(overrides = {}) {
  return {
    type: "buffer:message",
    version: 1,
    event_id: "message:11",
    id: 11,
    buffer_id: "channel:7",
    server_connection_id: 42,
    channel_membership_id: 7,
    direct_message_thread_id: null,
    nick: "mira",
    hostmask: null,
    sender_role: null,
    service: null,
    metadata: {},
    body: "hello",
    kind: "message",
    mentioned: false,
    occurred_at: occurredAt,
    ...overrides,
  }
}

function directMessageThread(overrides = {}) {
  return {
    type: "direct_message:thread",
    version: 1,
    event_id: "direct_message_thread:8:1",
    occurred_at: occurredAt,
    revision: 1,
    connection: connection(),
    buffer: {
      buffer_id: "direct:8",
      buffer_type: "direct_message",
      server_connection_id: 42,
      direct_message_thread_id: 8,
      direct_message_revision: 1,
      title: "akash",
      subtitle: "on irc.example.test",
      peer_nick: "akash",
      account: null,
      hostmask: null,
      blocked: false,
      closed_at: null,
      unread_count: 1,
      mention_count: 0,
    },
    ...overrides,
  }
}

describe("realtime client", () => {
  test("connects one socket to the authenticated user channel", () => {
    const onBufferMessage = vi.fn()
    const client = createRealtimeClient({
      SocketClass: FakeSocket,
      csrfToken: "csrf",
      userId: 7,
      handlers: {onBufferMessage},
    })

    client.connect()
    const message = messageEnvelope({
      occurredAt: "invalid",
      clientMessageId: "wire-client-id",
      pending: true,
      failed: true,
    })
    client.channel.handlers["buffer:message"](message)

    expect(client.socket.path).toBe("/socket")
    expect(client.socket.options.params).toEqual({_csrf_token: "csrf"})
    expect(client.socket.options.longPollFallbackMs).toBe(2500)
    expect(client.socket.topic).toBe("user:7")
    expect(client.connectionState()).toBe("open")
    expect(onBufferMessage).toHaveBeenCalledWith(expect.objectContaining({
      id: message.id,
      occurred_at: message.occurred_at,
    }))
    expect(onBufferMessage.mock.calls[0][0]).not.toHaveProperty("occurredAt")
    expect(onBufferMessage.mock.calls[0][0]).not.toHaveProperty("clientMessageId")
    expect(onBufferMessage.mock.calls[0][0]).not.toHaveProperty("pending")
    expect(onBufferMessage.mock.calls[0][0]).not.toHaveProperty("failed")
    expect(client.channel.handlers.message).toBeUndefined()
  })

  test("forwards only canonical buffer left events", () => {
    const onBufferLeft = vi.fn()
    const client = createRealtimeClient({
      SocketClass: FakeSocket,
      userId: 7,
      handlers: {onBufferLeft},
    })

    const left = {
      type: "buffer:left",
      version: 1,
      event_id: "buffer_left:channel:7:1",
      occurred_at: occurredAt,
      buffer_id: "channel:7",
      server_connection_id: 42,
      channel_membership_id: 7,
    }
    client.channel.handlers["buffer:left"](left)
    client.channel.handlers["buffer:left"]({...left, buffer_id: "channel:8"})
    client.channel.handlers["buffer:left"]({buffer_id: "channel:7"})

    expect(onBufferLeft).toHaveBeenCalledOnce()
    expect(onBufferLeft).toHaveBeenCalledWith(left)
  })

  test("forwards only canonical buffer joined events", () => {
    const onBufferJoined = vi.fn()
    const client = createRealtimeClient({
      SocketClass: FakeSocket,
      userId: 7,
      handlers: {onBufferJoined},
    })

    const joined = {
      type: "buffer:joined",
      version: 1,
      event_id: "buffer_joined:channel:7:1",
      occurred_at: occurredAt,
      connection: connection(),
      buffer: channelBuffer(),
    }
    client.channel.handlers["buffer:joined"](joined)
    client.channel.handlers["buffer:joined"]({
      ...joined,
      buffer: channelBuffer({server_connection_id: 99}),
    })
    client.channel.handlers["buffer:joined"]({buffer: {buffer_id: "channel:7"}})

    expect(onBufferJoined).toHaveBeenCalledOnce()
    expect(onBufferJoined).toHaveBeenCalledWith(joined)
  })

  test("forwards only canonical presence payloads", () => {
    const handlers = {onPresenceSync: vi.fn(), onPresenceDiff: vi.fn()}
    const client = createRealtimeClient({SocketClass: FakeSocket, userId: 7, handlers})

    const sync = presenceEnvelope("presence:sync", {
      users: [{nick: "[Mira]", nick_key: "{mira}", role: "op", status: "online"}],
    })

    const diff = presenceEnvelope("presence:diff", {
      diff: {
        action: "nick",
        old_nick: "[Mira]",
        old_nick_key: "{mira}",
        new_nick: "Other",
        new_nick_key: "other",
      },
    })

    client.channel.handlers["presence:sync"](sync)
    client.channel.handlers["presence:diff"](diff)
    client.channel.handlers["presence:sync"](
      presenceEnvelope("presence:sync", {users: [{nick: "missing-key"}]})
    )
    client.channel.handlers["presence:sync"](
      presenceEnvelope("presence:sync", {
        users: [
          {nick: "[Mira]", nick_key: "{mira}"},
          {nick: "{MIRA}", nick_key: "{mira}"},
        ],
      })
    )
    client.channel.handlers["presence:sync"](
      presenceEnvelope("presence:sync", {buffer_id: "channel:8", users: []})
    )
    client.channel.handlers["presence:sync"]({buffer_id: "channel:7", users: []})
    client.channel.handlers["presence:diff"](
      presenceEnvelope("presence:diff", {diff: {action: "part", nick: "Mira"}})
    )

    expect(handlers.onPresenceSync).toHaveBeenCalledOnce()
    expect(handlers.onPresenceSync).toHaveBeenCalledWith(sync)
    expect(handlers.onPresenceDiff).toHaveBeenCalledOnce()
    expect(handlers.onPresenceDiff).toHaveBeenCalledWith(diff)
  })

  test("forwards only canonical direct-message lifecycle events", () => {
    const handlers = {
      onDirectMessageThread: vi.fn(),
      onDirectMessageClosed: vi.fn(),
    }
    const client = createRealtimeClient({SocketClass: FakeSocket, userId: 7, handlers})

    const thread = directMessageThread()
    client.channel.handlers["direct_message:thread"](thread)
    client.channel.handlers["direct_message:thread"]({
      ...thread,
      buffer: {...thread.buffer, buffer_id: "direct:9"},
    })
    const closed = {
      type: "direct_message:closed",
      version: 1,
      event_id: "direct_message_closed:8:1",
      occurred_at: "2026-08-26T00:00:00Z",
      buffer_id: "direct:8",
      server_connection_id: 42,
      direct_message_thread_id: 8,
      revision: 1,
    }
    client.channel.handlers["direct_message:closed"](closed)
    client.channel.handlers["direct_message:closed"]({...closed, buffer_id: "direct:9"})

    expect(handlers.onDirectMessageThread).toHaveBeenCalledOnce()
    expect(handlers.onDirectMessageThread).toHaveBeenCalledWith(thread)
    expect(handlers.onDirectMessageClosed).toHaveBeenCalledOnce()
    expect(handlers.onDirectMessageClosed).toHaveBeenCalledWith(closed)
  })

  test("forwards only canonical buffer error events through the timeline message handler", () => {
    const onBufferMessage = vi.fn()
    const client = createRealtimeClient({
      SocketClass: FakeSocket,
      userId: 7,
      handlers: {onBufferMessage},
    })

    const message = messageEnvelope({
      type: "buffer:error",
      body: "connection failed",
      kind: "error",
    })
    client.channel.handlers["buffer:error"](message)
    client.channel.handlers["buffer:error"]({...message, event_id: "message:12"})

    expect(onBufferMessage).toHaveBeenCalledOnce()
    expect(onBufferMessage).toHaveBeenCalledWith(message)
  })

  test("forwards only canonical buffer system events through the timeline message handler", () => {
    const onBufferMessage = vi.fn()
    const client = createRealtimeClient({
      SocketClass: FakeSocket,
      userId: 7,
      handlers: {onBufferMessage},
    })

    const message = messageEnvelope({
      type: "buffer:system",
      body: "akash joined #elixir",
      kind: "join",
    })
    client.channel.handlers["buffer:system"](message)
    client.channel.handlers["buffer:system"]({...message, channel_membership_id: 8})

    expect(onBufferMessage).toHaveBeenCalledOnce()
    expect(onBufferMessage).toHaveBeenCalledWith(message)
  })

  test("forwards only canonical read, status, and notification preference payloads", () => {
    const handlers = {
      onBufferRead: vi.fn(),
      onServerStatus: vi.fn(),
      onNotificationPreference: vi.fn(),
    }
    const client = createRealtimeClient({SocketClass: FakeSocket, userId: 7, handlers})
    const read = {
      type: "buffer:read",
      version: 1,
      event_id: "buffer_read:channel:7:1",
      occurred_at: occurredAt,
      buffer_id: "channel:7",
      server_connection_id: 42,
      channel_membership_id: 7,
      unread_count: 0,
      mention_count: 0,
    }
    const status = {
      type: "server:status",
      version: 1,
      event_id: "server_status:42:1",
      occurred_at: occurredAt,
      server_connection_id: 42,
      nickname: "mira",
      status: "connected",
    }
    const preference = {
      type: "notification:preference",
      version: 1,
      event_id: "notification_preference:channel:7:1",
      occurred_at: occurredAt,
      scope: "channel",
      id: 7,
      mention_notifications_enabled: false,
      revision: 1,
    }

    client.channel.handlers["buffer:read"](read)
    client.channel.handlers["buffer:read"]({...read, channel_membership_id: 8})
    client.channel.handlers["server:status"](status)
    client.channel.handlers["server:status"]({...status, event_id: "server_status:99:1"})
    client.channel.handlers["notification:preference"](preference)
    client.channel.handlers["notification:preference"]({
      scope: "channel",
      id: 7,
      mention_notifications_enabled: false,
      revision: 1,
    })
    client.channel.handlers["notification:preference"]({...preference, revision: -1})

    expect(handlers.onBufferRead).toHaveBeenCalledOnce()
    expect(handlers.onBufferRead).toHaveBeenCalledWith(read)
    expect(handlers.onServerStatus).toHaveBeenCalledOnce()
    expect(handlers.onServerStatus).toHaveBeenCalledWith(status)
    expect(handlers.onNotificationPreference).toHaveBeenCalledOnce()
    expect(handlers.onNotificationPreference).toHaveBeenCalledWith(preference)
  })

  test("forwards authoritative nonzero counters from a delayed read event", () => {
    const onBufferRead = vi.fn()
    const client = createRealtimeClient({SocketClass: FakeSocket, userId: 7, handlers: {onBufferRead}})
    const read = {
      type: "buffer:read",
      version: 1,
      event_id: "buffer_read:channel:7:2",
      occurred_at: occurredAt,
      buffer_id: "channel:7",
      server_connection_id: 42,
      channel_membership_id: 7,
      unread_count: 2,
      mention_count: 1,
    }

    client.channel.handlers["buffer:read"](read)

    expect(onBufferRead).toHaveBeenCalledWith(read)
  })

  test("wraps channel pushes in ok/error/timeout promises", async () => {
    const client = createRealtimeClient({SocketClass: FakeSocket, userId: 7})

    await expect(client.push("message:send", {body: "hello"}, 500)).resolves.toEqual({accepted: true})

    expect(client.channel.pushed).toEqual({
      event: "message:send",
      payload: {body: "hello"},
      timeout: 500,
    })
  })

  test("wraps channel push timeouts in typed payloads", async () => {
    const client = createRealtimeClient({SocketClass: TimeoutSocket, userId: 7})

    await expect(client.push("message:send", {body: "hello"}, 500)).rejects.toEqual({
      reply: "timeout",
      reason: "timeout",
    })
  })

  test("forwards socket and channel lifecycle events to handlers", () => {
    const handlers = {
      onOpen: vi.fn(),
      onClose: vi.fn(),
      onError: vi.fn(),
      onChannelError: vi.fn(),
      onChannelClose: vi.fn(),
    }
    const client = createRealtimeClient({SocketClass: FakeSocket, userId: 7, handlers})

    client.socket.lifecycleHandlers.open()
    client.socket.lifecycleHandlers.close({code: 1006})
    client.socket.lifecycleHandlers.error(new Error("boom"))
    client.channel.handlers.phx_error({reason: "server restart"})
    client.channel.handlers.phx_close("closed")

    expect(handlers.onOpen).toHaveBeenCalledOnce()
    expect(handlers.onClose).toHaveBeenCalledWith({code: 1006})
    expect(handlers.onError).toHaveBeenCalledWith(expect.any(Error))
    expect(handlers.onChannelError).toHaveBeenCalledWith({reason: "server restart"})
    expect(handlers.onChannelClose).toHaveBeenCalledWith("closed")
  })

  test("disconnects the channel and socket", () => {
    const client = createRealtimeClient({SocketClass: FakeSocket, userId: 7})

    client.disconnect()

    expect(client.channel.left).toBe(true)
    expect(client.socket.disconnected).toBe(true)
  })

  test("reconnects the socket without joining a channel instance twice", () => {
    const client = createRealtimeClient({SocketClass: FakeSocket, userId: 7})

    client.connect()
    client.reconnect()

    expect(client.channel.left).toBe(false)
    expect(client.socket.disconnected).toBe(true)
    expect(client.socket.connected).toBe(true)
    expect(client.socket.connectCount).toBe(2)
    expect(client.channel.joinCount).toBe(1)
  })
})
