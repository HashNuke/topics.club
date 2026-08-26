import {afterEach, describe, expect, test, vi} from "vitest"
import {
  notificationControlState,
  notificationDeliveryCoveredByPush,
  resetNotificationInstallationMemoryForTest,
  synchronizeNotificationDevice,
} from "./push_notifications.ts"
import type {NotificationDeviceState} from "./browser_notifications.ts"

const INSTALLATION_KEY = "ircpipe.notification-installation"
const originalNotification = window.Notification
const originalPushManager = window.PushManager
const originalServiceWorker = navigator.serviceWorker

afterEach(() => {
  vi.restoreAllMocks()
  localStorage.clear()
  resetNotificationInstallationMemoryForTest()

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
    const oldSubscription = {
      unsubscribe: vi.fn().mockResolvedValue(true),
      toJSON: () => ({
        endpoint: "https://push.example.test/old-account",
        keys: {p256dh: "old-public-key", auth: "old-auth"},
      }),
    }
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
    const savePushSubscription = vi.fn()
      .mockRejectedValueOnce(new Error("push_subscription_owned_by_another_account"))
      .mockResolvedValue({subscription: {installation_id: "new"}})
    configurePushBrowser(registration)
    localStorage.setItem(INSTALLATION_KEY, JSON.stringify({installation_id: "old", user_id: "1"}))

    const state = await synchronizeNotificationDevice(
      {savePushSubscription} as any,
      {configured: true, vapid_public_key: "AQ"},
      2
    )

    expect(oldSubscription.unsubscribe).toHaveBeenCalledOnce()
    expect(registration.pushManager.subscribe).toHaveBeenCalledOnce()
    expect(savePushSubscription).toHaveBeenLastCalledWith(
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

  test("preserves a confirmed server registration during a transient resync failure", async () => {
    const subscription = {
      toJSON: () => ({
        endpoint: "https://push.example.test/confirmed-account",
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
    localStorage.setItem(INSTALLATION_KEY, JSON.stringify({
      installation_id: "confirmed",
      user_id: "2",
      server_registration_confirmed: true,
    }))

    const state = await synchronizeNotificationDevice(
      {savePushSubscription: vi.fn().mockRejectedValue(new Error("temporary outage"))} as any,
      {configured: true, vapid_public_key: "AQ"},
      2
    )

    expect(state).toMatchObject({
      loading: false,
      subscribed: true,
      error: "Notifications are enabled locally but could not be synchronized.",
    })
  })

  test("a second tab observes a server registration confirmed by the first", async () => {
    const subscription = {
      toJSON: () => ({
        endpoint: "https://push.example.test/shared-tabs",
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
    localStorage.setItem(INSTALLATION_KEY, JSON.stringify({
      installation_id: "shared-browser",
      user_id: "2",
      server_registration_confirmed: false,
    }))

    const firstTab = await synchronizeNotificationDevice(
      {savePushSubscription: vi.fn().mockResolvedValue({subscription: {installation_id: "shared-browser"}})} as any,
      {configured: true, vapid_public_key: "AQ"},
      2
    )
    const secondTab = await synchronizeNotificationDevice(
      {savePushSubscription: vi.fn().mockRejectedValue(new Error("temporary outage"))} as any,
      {configured: true, vapid_public_key: "AQ"},
      2
    )

    expect(firstTab.subscribed).toBe(true)
    expect(secondTab.subscribed).toBe(true)
    expect(JSON.parse(localStorage.getItem(INSTALLATION_KEY)!)).toMatchObject({
      server_registration_confirmed: true,
    })

    const staleSecondTabState = device({subscribed: false})
    expect(notificationDeliveryCoveredByPush(staleSecondTabState, 2)).toBe(true)
  })

  test("recovers one installation identity across page lifecycles when durable storage is denied", async () => {
    const subscription = {
      unsubscribe: vi.fn().mockResolvedValue(true),
      toJSON: () => ({
        endpoint: "https://push.example.test/storage-denied",
        keys: {p256dh: "public-key", auth: "auth"},
      }),
    }
    const registration = {
      pushManager: {
        getSubscription: vi.fn().mockResolvedValue(subscription),
        subscribe: vi.fn(),
      },
    }
    const savePushSubscription = vi.fn().mockResolvedValue({
      subscription: {installation_id: "server-canonical-installation"},
    })
    configurePushBrowser(registration)
    vi.spyOn(Storage.prototype, "getItem").mockImplementation(() => {
      throw new DOMException("Storage denied")
    })
    vi.spyOn(Storage.prototype, "setItem").mockImplementation(() => {
      throw new DOMException("Storage denied")
    })

    const apiClient = {savePushSubscription} as any
    const push = {
      configured: true,
      vapid_public_key: "AQ",
      session_generation: "current-session",
      session_installation_id: "server-canonical-installation",
      session_registration_confirmed: true,
    }
    const first = await synchronizeNotificationDevice(apiClient, push, 2)

    vi.resetModules()
    const reloadedModule = await import("./push_notifications.ts")
    const second = await reloadedModule.synchronizeNotificationDevice(apiClient, push, 2)

    expect(first.subscribed).toBe(true)
    expect(second.subscribed).toBe(true)
    expect(subscription.unsubscribe).not.toHaveBeenCalled()
    expect(registration.pushManager.subscribe).not.toHaveBeenCalled()
    expect(savePushSubscription).toHaveBeenCalledTimes(2)
    expect(savePushSubscription.mock.calls[0][0]).toBe("server-canonical-installation")
    expect(savePushSubscription.mock.calls[1][0]).toBe("server-canonical-installation")
  })

  test("does not trust a prior session registration after a password reset", async () => {
    const subscription = {
      toJSON: () => ({
        endpoint: "https://push.example.test/reset-session",
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
    localStorage.setItem(INSTALLATION_KEY, JSON.stringify({
      installation_id: "pre-reset-installation",
      user_id: "2",
      session_generation: "revoked-session",
      server_registration_confirmed: true,
    }))

    const push = {
      configured: true,
      vapid_public_key: "AQ",
      session_generation: "replacement-session",
      session_installation_id: null,
      session_registration_confirmed: false,
    }
    const state = await synchronizeNotificationDevice(
      {savePushSubscription: vi.fn().mockRejectedValue(new Error("temporary outage"))} as any,
      push,
      2
    )

    expect(state.subscribed).toBe(false)
    expect(notificationDeliveryCoveredByPush(state, 2, push)).toBe(false)
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
