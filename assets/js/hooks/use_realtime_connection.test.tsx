import {useRef} from "react"
import {act, renderHook} from "@testing-library/react"
import {describe, expect, test, vi} from "vitest"
import useRealtimeConnection from "./use_realtime_connection.ts"

describe("useRealtimeConnection", () => {
  test("connects, forwards events, tracks health, and retries", async () => {
    let realtimeHandlers
    const reconnect = vi.fn()
    const disconnect = vi.fn()
    const connectedClient = {reconnect}
    const realtimeClientFactory = vi.fn(({handlers}) => {
      realtimeHandlers = handlers
      return {connect: () => connectedClient, disconnect}
    })
    const onMessage = vi.fn()
    const onConnected = vi.fn()
    const {result, unmount} = renderHook(() => {
      const realtimeClientRef = useRef(null)
      return useRealtimeConnection({
        handlers: {onMessage},
        onConnected,
        realtimeClientFactory,
        realtimeClientRef,
        sessionKey: 1,
      })
    })

    expect(result.current.realtimeClientRef.current).toBe(connectedClient)
    act(() => realtimeHandlers.onMessage({body: "hello"}))
    expect(onMessage).toHaveBeenCalledWith({body: "hello"})

    await act(async () => realtimeHandlers.onOpen())
    expect(result.current.connectionHealth).toBe("reconnecting")
    expect(onConnected).not.toHaveBeenCalled()

    await act(async () => realtimeHandlers.onJoinOk())
    expect(result.current.connectionHealth).toBe("connected")
    expect(onConnected).toHaveBeenCalledTimes(1)

    act(() => realtimeHandlers.onChannelError({reason: "server restart"}))
    expect(result.current.connectionHealth).toBe("reconnecting")
    await act(async () => realtimeHandlers.onJoinOk())
    expect(result.current.connectionHealth).toBe("connected")
    expect(onConnected).toHaveBeenCalledTimes(2)

    act(() => realtimeHandlers.onChannelClose("closed"))
    expect(result.current.connectionHealth).toBe("degraded")

    act(() => realtimeHandlers.onClose())
    await act(async () => realtimeHandlers.onJoinOk())
    expect(onConnected).toHaveBeenCalledTimes(3)

    act(() => result.current.retryRealtimeConnection())
    expect(result.current.connectionHealth).toBe("reconnecting")
    expect(reconnect).toHaveBeenCalledTimes(1)

    unmount()
    expect(disconnect).toHaveBeenCalledTimes(1)
  })

  test("creates a fresh client generation when retrying after a permanent channel close", async () => {
    const generations = []
    const realtimeClientFactory = vi.fn(({handlers}) => {
      const client = {
        connect: vi.fn(),
        disconnect: vi.fn(),
        reconnect: vi.fn(),
      }
      client.connect.mockReturnValue(client)
      generations.push({client, handlers})
      return client
    })
    const onConnected = vi.fn()
    const {result} = renderHook(() => useRealtimeConnection({
      handlers: {},
      onConnected,
      realtimeClientFactory,
      sessionKey: 1,
    }))

    expect(generations).toHaveLength(1)
    act(() => generations[0].handlers.onChannelClose("closed"))
    expect(result.current.connectionHealth).toBe("degraded")

    act(() => result.current.retryRealtimeConnection())

    expect(generations).toHaveLength(2)
    expect(generations[0].client.disconnect).toHaveBeenCalledOnce()
    expect(generations[0].client.reconnect).not.toHaveBeenCalled()
    expect(generations[1].client.connect).toHaveBeenCalledOnce()

    await act(async () => generations[1].handlers.onJoinOk())
    expect(result.current.connectionHealth).toBe("connected")
    expect(onConnected).toHaveBeenCalledOnce()
  })
})
