import {renderHook} from "@testing-library/react"
import {describe, expect, test, vi} from "vitest"
import useActivityHeartbeat from "./use_activity_heartbeat.js"

describe("useActivityHeartbeat", () => {
  test("touches activity initially and on focus, then removes its listener", () => {
    const activity = vi.fn().mockResolvedValue({})
    const apiClient = {activity}
    const {unmount} = renderHook(() => useActivityHeartbeat(apiClient, true))

    expect(activity).toHaveBeenCalledTimes(1)
    window.dispatchEvent(new Event("focus"))
    expect(activity).toHaveBeenCalledTimes(2)

    unmount()
    window.dispatchEvent(new Event("focus"))
    expect(activity).toHaveBeenCalledTimes(2)
  })

  test("does nothing while disabled", () => {
    const activity = vi.fn().mockResolvedValue({})
    renderHook(() => useActivityHeartbeat({activity}, false))
    expect(activity).not.toHaveBeenCalled()
  })
})
