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
    expect(result.current.connectionHealth).toBe("connected")
    expect(onConnected).toHaveBeenCalledTimes(1)

    act(() => result.current.retryRealtimeConnection())
    expect(result.current.connectionHealth).toBe("reconnecting")
    expect(reconnect).toHaveBeenCalledTimes(1)

    unmount()
    expect(disconnect).toHaveBeenCalledTimes(1)
  })
})
