import {describe, expect, test, vi} from "vitest"
import {createRealtimeClient} from "./realtime_client.js"

class FakeSocket {
  constructor(path, options) {
    this.path = path
    this.options = options
    this.connected = false
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
  }

  disconnect() {
    this.disconnected = true
  }

  connectionState() {
    return this.connected ? "open" : "closed"
  }
}

class FakeChannel {
  constructor() {
    this.handlers = {}
    this.left = false
  }

  on(event, callback) {
    this.handlers[event] = callback
  }

  join() {
    return receiver()
  }

  push(event, payload, timeout) {
    this.pushed = {event, payload, timeout}
    return receiver({ok: {accepted: true}})
  }

  leave() {
    this.left = true
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

    expect(client.socket.path).toBe("/socket")
    expect(client.socket.options.params).toEqual({_csrf_token: "csrf"})
    expect(client.socket.topic).toBe("user:7")
    expect(client.connectionState()).toBe("open")
    expect(onMessage).toHaveBeenCalledWith({body: "hello"})
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

  test("forwards socket lifecycle events to handlers", () => {
    const handlers = {
      onOpen: vi.fn(),
      onClose: vi.fn(),
      onError: vi.fn(),
    }
    const client = createRealtimeClient({SocketClass: FakeSocket, userId: 7, handlers})

    client.socket.lifecycleHandlers.open()
    client.socket.lifecycleHandlers.close({code: 1006})
    client.socket.lifecycleHandlers.error(new Error("boom"))

    expect(handlers.onOpen).toHaveBeenCalledOnce()
    expect(handlers.onClose).toHaveBeenCalledWith({code: 1006})
    expect(handlers.onError).toHaveBeenCalledWith(expect.any(Error))
  })

  test("disconnects the channel and socket", () => {
    const client = createRealtimeClient({SocketClass: FakeSocket, userId: 7})

    client.disconnect()

    expect(client.channel.left).toBe(true)
    expect(client.socket.disconnected).toBe(true)
  })
})
