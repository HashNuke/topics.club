import {describe, expect, test} from "vitest"
import {notificationControlState} from "./push_notifications.ts"
import type {NotificationDeviceState} from "./browser_notifications.ts"

function device(overrides: Partial<NotificationDeviceState> = {}): NotificationDeviceState {
  return {
    capability: "granted",
    configured: true,
    loading: false,
    subscribed: true,
    ...overrides,
  }
}

describe("notificationControlState", () => {
  test("maps the device and preference gates to the four visual states", () => {
    expect(notificationControlState(device(), true, true)).toEqual({kind: "enabled"})
    expect(notificationControlState(device(), false, true)).toEqual({kind: "disabled"})
    expect(notificationControlState(device({subscribed: false}), true, true)).toEqual({kind: "available"})
    expect(notificationControlState(device({capability: "insecure"}), true, true)).toEqual({
      kind: "unavailable",
      reason: "Notifications require HTTPS or localhost.",
    })
  })

  test("explains when a parent server suppresses an enabled channel", () => {
    expect(notificationControlState(device(), true, false, "Libera Chat")).toEqual({
      kind: "disabled",
      reason: "Mentions are muted because Libera Chat notifications are off.",
    })
  })

  test("surfaces recoverable setup failures without making the control unavailable", () => {
    expect(notificationControlState(device({subscribed: false, error: "Push service timed out."}))).toEqual({
      kind: "available",
      reason: "Push service timed out.",
    })

    expect(notificationControlState(device({error: "Server synchronization failed."}))).toEqual({
      kind: "enabled",
      reason: "Server synchronization failed.",
    })
  })
})
