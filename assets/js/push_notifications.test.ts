import {afterEach, describe, expect, test, vi} from "vitest"
import {notificationControlState, synchronizeNotificationDevice} from "./push_notifications.ts"
import type {NotificationDeviceState} from "./browser_notifications.ts"

const INSTALLATION_KEY = "ircpipe.notification-installation"
const originalNotification = window.Notification
const originalPushManager = window.PushManager
const originalServiceWorker = navigator.serviceWorker

afterEach(() => {
  localStorage.clear()

  if (originalNotification) {
    Object.defineProperty(window, "Notification", {value: originalNotification, configurable: true})
  } else {
    delete window.Notification
  }

  if (originalPushManager) {
    Object.defineProperty(window, "PushManager", {value: originalPushManager, configurable: true})
  } else {
    delete window.PushManager
  }

  if (originalServiceWorker) {
    Object.defineProperty(navigator, "serviceWorker", {value: originalServiceWorker, configurable: true})
  } else {
    delete navigator.serviceWorker
  }
})

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

  test("rotates an origin subscription when the signed-in account changes", async () => {
    const oldSubscription = {unsubscribe: vi.fn().mockResolvedValue(true)}
    const newSubscription = {
      toJSON: () => ({
        endpoint: "https://push.example.test/new-account",
        keys: {p256dh: "new-public-key", auth: "new-auth"},
      }),
    }
    const registration = {
      pushManager: {
        getSubscription: vi.fn().mockResolvedValue(oldSubscription),
        subscribe: vi.fn().mockResolvedValue(newSubscription),
      },
    }
    const savePushSubscription = vi.fn().mockResolvedValue({subscription: {installation_id: "new"}})
    configurePushBrowser(registration)
    localStorage.setItem(INSTALLATION_KEY, JSON.stringify({installation_id: "old", user_id: "1"}))

    const state = await synchronizeNotificationDevice(
      {savePushSubscription} as any,
      {configured: true, vapid_public_key: "AQ"},
      2
    )

    expect(oldSubscription.unsubscribe).toHaveBeenCalledOnce()
    expect(registration.pushManager.subscribe).toHaveBeenCalledOnce()
    expect(savePushSubscription).toHaveBeenCalledWith(
      expect.not.stringMatching(/^old$/),
      newSubscription.toJSON()
    )
    expect(JSON.parse(localStorage.getItem(INSTALLATION_KEY)!)).toMatchObject({user_id: "2"})
    expect(state).toMatchObject({loading: false, subscribed: true})
  })

  test("does not suppress local fallback when server synchronization fails", async () => {
    const subscription = {
      toJSON: () => ({
        endpoint: "https://push.example.test/current-account",
        keys: {p256dh: "public-key", auth: "auth"},
      }),
    }
    const registration = {
      pushManager: {
        getSubscription: vi.fn().mockResolvedValue(subscription),
        subscribe: vi.fn(),
      },
    }
    configurePushBrowser(registration)
    localStorage.setItem(INSTALLATION_KEY, JSON.stringify({installation_id: "current", user_id: "2"}))

    const state = await synchronizeNotificationDevice(
      {savePushSubscription: vi.fn().mockRejectedValue(new Error("ownership conflict"))} as any,
      {configured: true, vapid_public_key: "AQ"},
      2
    )

    expect(state).toMatchObject({
      loading: false,
      subscribed: false,
      error: "Notifications are enabled locally but could not be synchronized.",
    })
  })
})

function configurePushBrowser(registration: unknown) {
  const NotificationMock = vi.fn()
  NotificationMock.permission = "granted"
  Object.defineProperty(window, "Notification", {value: NotificationMock, configurable: true})
  Object.defineProperty(window, "PushManager", {value: vi.fn(), configurable: true})
  Object.defineProperty(navigator, "serviceWorker", {
    value: {ready: Promise.resolve(registration)},
    configurable: true,
  })
}
