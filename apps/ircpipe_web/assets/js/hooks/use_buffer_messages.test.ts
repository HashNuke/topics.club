import {act, renderHook} from "@testing-library/react"
import {describe, expect, test, vi} from "vitest"
import useBufferMessages from "./use_buffer_messages.ts"

describe("useBufferMessages", () => {
  test("keeps all retained DM history when appending a local system message", async () => {
    const retained = Array.from({length: 450}, (_, index) => chatMessage(index + 1))
    const apiClient = {
      bufferMessages: vi.fn((_bufferId, params = {}) => {
        if (!params.before) return Promise.resolve({messages: retained.slice(-150)})
        const cursorIndex = retained.findIndex((message) => message.id === params.before)
        return Promise.resolve({
          messages: cursorIndex < 0
            ? []
            : retained.slice(Math.max(0, cursorIndex - 150), cursorIndex),
        })
      }),
    }
    const activeChannelIdRef = {current: "direct:9"}
    const connectionsRef = {
      current: [{
        id: "server:1",
        server_connection_id: 1,
        channels: [{id: "direct:9", buffer_type: "direct_message", channel: "Zed"}],
      }],
    }

    const {result} = renderHook(() => useBufferMessages({
      activeChannelIdRef,
      activeServerIdRef: {current: "server:1"},
      apiClient: apiClient as any,
      connectionsRef: connectionsRef as any,
      markBufferRead: vi.fn().mockResolvedValue(undefined),
      viewRef: {current: "chat"},
    }))

    await act(async () => result.current.hydrateDirectMessageHistory("direct:9"))
    expect(result.current.messagesByChannel["direct:9"]).toHaveLength(450)

    act(() => result.current.appendSystemMessage("Server join failed."))

    expect(result.current.messagesByChannel["direct:9"]).toHaveLength(451)
    expect(result.current.messagesByChannel["direct:9"][0].body).toBe("retained 1")
    expect(result.current.messagesByChannel["direct:9"].at(-1)?.body).toBe("Server join failed.")
  })

  test("restarts DM hydration when retention pruning causes overlapping pages", async () => {
    const staleRetained = Array.from({length: 450}, (_, index) => chatMessage(index + 1))
    const currentRetained = Array.from({length: 451}, (_, index) => chatMessage(index + 1))
    let requestCount = 0
    const apiClient = {
      bufferMessages: vi.fn((_bufferId, params = {}) => {
        requestCount += 1

        if (requestCount === 1) {
          return Promise.resolve({messages: staleRetained.slice(-150)})
        }
        if (!params.before || requestCount === 2) {
          return Promise.resolve({messages: currentRetained.slice(-150)})
        }

        const cursorIndex = currentRetained.findIndex((message) => message.id === params.before)
        return Promise.resolve({
          messages: cursorIndex < 0
            ? currentRetained.slice(-150)
            : currentRetained.slice(Math.max(0, cursorIndex - 150), cursorIndex),
        })
      }),
    }
    const connectionsRef = {
      current: [{
        id: "server:1",
        server_connection_id: 1,
        channels: [{id: "direct:9", buffer_type: "direct_message", channel: "Zed"}],
      }],
    }
    const {result} = renderHook(() => useBufferMessages({
      activeChannelIdRef: {current: "direct:9"},
      activeServerIdRef: {current: "server:1"},
      apiClient: apiClient as any,
      connectionsRef: connectionsRef as any,
      markBufferRead: vi.fn().mockResolvedValue(undefined),
      viewRef: {current: "chat"},
    }))

    await act(async () => result.current.hydrateDirectMessageHistory("direct:9"))

    const hydrated = result.current.messagesByChannel["direct:9"]
    expect(hydrated).toHaveLength(451)
    expect(new Set(hydrated.map((message) => message.id)).size).toBe(451)
    expect(hydrated[0].body).toBe("retained 1")
    expect(hydrated.at(-1)?.body).toBe("retained 451")
    expect(apiClient.bufferMessages).toHaveBeenCalledTimes(6)
  })

  test("accepts DM pages ordered by timestamp when message IDs are not monotonic", async () => {
    const retained = Array.from({length: 200}, (_, index) => ({
      ...chatMessage(1_000 - index),
      occurred_at: new Date(Date.UTC(2026, 7, 25, 15, 0, index)).toISOString(),
    }))
    const apiClient = {
      bufferMessages: vi.fn((_bufferId, params = {}) => {
        if (!params.before) return Promise.resolve({messages: retained.slice(-150)})
        const cursorIndex = retained.findIndex((message) => message.id === params.before)
        return Promise.resolve({messages: retained.slice(Math.max(0, cursorIndex - 150), cursorIndex)})
      }),
    }
    const connectionsRef = {
      current: [{
        id: "server:1",
        server_connection_id: 1,
        channels: [{id: "direct:9", buffer_type: "direct_message", channel: "Zed"}],
      }],
    }
    const {result} = renderHook(() => useBufferMessages({
      activeChannelIdRef: {current: "direct:9"},
      activeServerIdRef: {current: "server:1"},
      apiClient: apiClient as any,
      connectionsRef: connectionsRef as any,
      markBufferRead: vi.fn().mockResolvedValue(undefined),
      viewRef: {current: "chat"},
    }))

    await act(async () => result.current.hydrateDirectMessageHistory("direct:9"))

    const hydrated = result.current.messagesByChannel["direct:9"]
    expect(hydrated).toHaveLength(200)
    expect(hydrated[0].occurred_at).toBe(retained[0].occurred_at)
    expect(hydrated.at(-1)?.occurred_at).toBe(retained.at(-1)?.occurred_at)
  })
})

function chatMessage(id: number) {
  return {
    type: "buffer:message",
    version: 1,
    id,
    event_id: `message:${id}`,
    buffer_id: "direct:9",
    server_connection_id: 1,
    channel_membership_id: null,
    direct_message_thread_id: 9,
    occurred_at: new Date(Date.UTC(2026, 7, 25, 15, 0, id)).toISOString(),
    nick: "Zed",
    hostmask: null,
    sender_role: null,
    service: null,
    body: `retained ${id}`,
    kind: "message",
    mentioned: false,
    metadata: {},
  }
}
