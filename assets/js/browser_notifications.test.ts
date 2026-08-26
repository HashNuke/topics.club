import {afterEach, describe, expect, test, vi} from "vitest"
import {
  notificationPermission,
  requestNotificationPermission,
  showMentionNotification,
} from "./browser_notifications.ts"

const originalNotification = window.Notification
const originalVisibilityState = document.visibilityState

afterEach(() => {
  if (originalNotification) {
    Object.defineProperty(window, "Notification", {value: originalNotification, configurable: true})
  } else {
    delete window.Notification
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
})
