import {afterEach, describe, expect, test, vi} from "vitest"
import {
  initialNotificationDeviceState,
  notificationPermission,
  notificationUnavailableReason,
  requestNotificationPermission,
} from "./browser_notifications.ts"

const originalNotification = window.Notification
const originalSecureContext = window.isSecureContext

afterEach(() => {
  if (originalNotification) {
    Object.defineProperty(window, "Notification", {value: originalNotification, configurable: true})
  } else {
    delete window.Notification
  }

  if (originalSecureContext === undefined) {
    delete window.isSecureContext
  } else {
    Object.defineProperty(window, "isSecureContext", {value: originalSecureContext, configurable: true})
  }
})

describe("browser notification capability", () => {
  test("reports and requests notification permission", async () => {
    const NotificationMock = vi.fn()
    NotificationMock.permission = "default"
    NotificationMock.requestPermission = vi.fn().mockResolvedValue("granted")
    Object.defineProperty(window, "Notification", {value: NotificationMock, configurable: true})

    expect(notificationPermission()).toBe("default")
    expect(initialNotificationDeviceState()).toEqual({
      capability: "default",
      configured: false,
      loading: true,
      subscribed: false,
    })
    await expect(requestNotificationPermission()).resolves.toBe("granted")
  })

  test("reports notifications as unavailable in an insecure context", async () => {
    const NotificationMock = vi.fn()
    NotificationMock.permission = "default"
    NotificationMock.requestPermission = vi.fn()
    Object.defineProperty(window, "Notification", {value: NotificationMock, configurable: true})
    Object.defineProperty(window, "isSecureContext", {value: false, configurable: true})

    expect(notificationPermission()).toBe("insecure")
    await expect(requestNotificationPermission()).resolves.toBe("insecure")
    expect(NotificationMock.requestPermission).not.toHaveBeenCalled()
  })

  test("reports notifications as unsupported when the API is missing", async () => {
    delete window.Notification

    expect(notificationPermission()).toBe("unsupported")
    await expect(requestNotificationPermission()).resolves.toBe("unsupported")
  })

  test("explains authoritative Web Push availability states", () => {
    expect(notificationUnavailableReason({
      capability: "granted",
      configured: false,
      loading: false,
      subscribed: false,
    })).toBe("Push notifications are not configured on this server.")
    expect(notificationUnavailableReason({
      capability: "denied",
      configured: true,
      loading: false,
      subscribed: false,
    })).toBe("Notifications are blocked in browser or operating-system settings.")
  })
})
