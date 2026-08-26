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

describe("realtime client", () => {
  test("connects one socket to the authenticated user channel", () => {
    const onMessage = vi.fn()
    const client = createRealtimeClient({
      SocketClass: FakeSocket,
      csrfToken: "csrf",
      userId: 7,
      handlers: {onMessage},
    })

    client.connect()
    client.channel.handlers.message({body: "hello"})
    client.channel.handlers["buffer:left"]({buffer_id: "channel:7"})

    expect(client.socket.path).toBe("/socket")
    expect(client.socket.options.params).toEqual({_csrf_token: "csrf"})
    expect(client.socket.options.longPollFallbackMs).toBe(2500)
    expect(client.socket.topic).toBe("user:7")
    expect(client.connectionState()).toBe("open")
    expect(onMessage).toHaveBeenCalledWith({body: "hello"})
  })

  test("forwards buffer left events", () => {
    const onBufferLeft = vi.fn()
    const client = createRealtimeClient({
      SocketClass: FakeSocket,
      userId: 7,
      handlers: {onBufferLeft},
    })

    client.channel.handlers["buffer:left"]({buffer_id: "channel:7"})

    expect(onBufferLeft).toHaveBeenCalledWith({buffer_id: "channel:7"})
  })

  test("forwards buffer joined events", () => {
    const onBufferJoined = vi.fn()
    const client = createRealtimeClient({
      SocketClass: FakeSocket,
      userId: 7,
      handlers: {onBufferJoined},
    })

    client.channel.handlers["buffer:joined"]({buffer: {buffer_id: "channel:8"}})

    expect(onBufferJoined).toHaveBeenCalledWith({buffer: {buffer_id: "channel:8"}})
  })

  test("forwards direct-message lifecycle events", () => {
    const handlers = {
      onDirectMessageThread: vi.fn(),
      onDirectMessageClosed: vi.fn(),
    }
    const client = createRealtimeClient({SocketClass: FakeSocket, userId: 7, handlers})

    client.channel.handlers["direct_message:thread"]({buffer: {buffer_id: "direct:8"}})
    const closed = {
      type: "direct_message:closed",
      version: 1,
      event_id: "direct_message_closed:8:1",
      occurred_at: "2026-08-26T00:00:00Z",
      buffer_id: "direct:8",
      server_connection_id: 1,
      direct_message_thread_id: 8,
      revision: 1,
    }
    client.channel.handlers["direct_message:closed"](closed)

    expect(handlers.onDirectMessageThread).toHaveBeenCalledWith({buffer: {buffer_id: "direct:8"}})
    expect(handlers.onDirectMessageClosed).toHaveBeenCalledWith(closed)
  })

  test("forwards buffer error events through the timeline message handler", () => {
    const onBufferMessage = vi.fn()
    const client = createRealtimeClient({
      SocketClass: FakeSocket,
      userId: 7,
      handlers: {onBufferMessage},
    })

    client.channel.handlers["buffer:error"]({type: "buffer:error", body: "connection failed"})

    expect(onBufferMessage).toHaveBeenCalledWith({type: "buffer:error", body: "connection failed"})
  })

  test("forwards buffer system events through the timeline message handler", () => {
    const onBufferMessage = vi.fn()
    const client = createRealtimeClient({
      SocketClass: FakeSocket,
      userId: 7,
      handlers: {onBufferMessage},
    })

    client.channel.handlers["buffer:system"]({type: "buffer:system", body: "akash joined #elixir"})

    expect(onBufferMessage).toHaveBeenCalledWith({type: "buffer:system", body: "akash joined #elixir"})
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
