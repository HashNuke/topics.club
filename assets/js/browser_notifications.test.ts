import {afterEach, describe, expect, test, vi} from "vitest"
import {
  notificationPermission,
  requestNotificationPermission,
  showMentionNotification,
} from "./browser_notifications.ts"

const originalNotification = window.Notification
const originalSecureContext = window.isSecureContext
const originalVisibilityState = document.visibilityState

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
  Object.defineProperty(document, "visibilityState", {value: originalVisibilityState, configurable: true})
})

describe("browser notifications", () => {
  test("reports and requests notification permission", async () => {
    const NotificationMock = vi.fn()
    NotificationMock.permission = "default"
    NotificationMock.requestPermission = vi.fn().mockResolvedValue("granted")
    Object.defineProperty(window, "Notification", {value: NotificationMock, configurable: true})

    expect(notificationPermission()).toBe("default")
    await expect(requestNotificationPermission()).resolves.toBe("granted")
  })

  test("shows hidden-page mentions from another user", () => {
    const NotificationMock = vi.fn()
    NotificationMock.permission = "granted"
    Object.defineProperty(window, "Notification", {value: NotificationMock, configurable: true})
    Object.defineProperty(document, "visibilityState", {value: "hidden", configurable: true})

    expect(showMentionNotification(
      {nick: "akash", channel: "#elixir", body: "mira: ping"},
      {currentUser: {email: "mira@example.com"}, notificationState: "granted"}
    )).toBe(true)
    expect(NotificationMock).toHaveBeenCalledWith("#elixir", {body: "akash: mira: ping"})

    expect(showMentionNotification(
      {nick: "mira", channel: "#elixir", body: "self"},
      {currentUser: {email: "mira@example.com"}, notificationState: "granted"}
    )).toBe(false)
  })

  test("reports notifications as unavailable in an insecure context", async () => {
    const NotificationMock = vi.fn()
    NotificationMock.permission = "default"
    NotificationMock.requestPermission = vi.fn()
    Object.defineProperty(window, "Notification", {value: NotificationMock, configurable: true})
    Object.defineProperty(window, "isSecureContext", {value: false, configurable: true})
    Object.defineProperty(document, "visibilityState", {value: "hidden", configurable: true})

    expect(notificationPermission()).toBe("insecure")
    await expect(requestNotificationPermission()).resolves.toBe("insecure")
    expect(NotificationMock.requestPermission).not.toHaveBeenCalled()
    expect(showMentionNotification(
      {nick: "akash", channel: "#elixir", body: "mira: ping"},
      {currentUser: {email: "mira@example.com"}, notificationState: "insecure"}
    )).toBe(false)
  })

  test("reports notifications as unsupported when the API is missing", async () => {
    delete window.Notification

    expect(notificationPermission()).toBe("unsupported")
    await expect(requestNotificationPermission()).resolves.toBe("unsupported")
  })
})
