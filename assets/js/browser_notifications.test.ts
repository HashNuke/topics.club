import {afterEach, describe, expect, test, vi} from "vitest"
import {
  createNotificationEventCoordinator,
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

  test("uses the peer nick as the title for a direct message", () => {
    const NotificationMock = vi.fn()
    NotificationMock.permission = "granted"
    Object.defineProperty(window, "Notification", {value: NotificationMock, configurable: true})
    Object.defineProperty(document, "visibilityState", {value: "hidden", configurable: true})

    expect(showMentionNotification(
      {nick: "akash", peer_nick: "akash", body: "hello privately"},
      {currentUser: {email: "mira@example.com"}, notificationState: "granted"}
    )).toBe(true)
    expect(NotificationMock).toHaveBeenCalledWith("akash", {body: "akash: hello privately"})
  })

  test("elects one tab to show a shared notification event", async () => {
    const NotificationMock = vi.fn()
    NotificationMock.permission = "granted"
    Object.defineProperty(window, "Notification", {value: NotificationMock, configurable: true})
    Object.defineProperty(document, "visibilityState", {value: "hidden", configurable: true})
    const channelFactory = inMemoryBroadcastChannelFactory()
    const firstTab = createNotificationEventCoordinator({
      channelFactory,
      claimWindowMs: 1,
      scope: "user-1",
      storage: null,
      tabId: "tab-a",
    })
    const secondTab = createNotificationEventCoordinator({
      channelFactory,
      claimWindowMs: 1,
      scope: "user-1",
      storage: null,
      tabId: "tab-b",
    })
    const message = {
      event_id: "notification:shared",
      nick: "akash",
      channel: "#elixir",
      body: "mira: only once",
    }

    const claims = await Promise.all([
      firstTab.claim(message.event_id),
      secondTab.claim(message.event_id),
    ])

    claims.forEach((claimed) => {
      if (claimed) {
        showMentionNotification(message, {
          currentUser: {email: "mira@example.com"},
          notificationState: "granted",
        })
      }
    })

    expect(claims.filter(Boolean)).toHaveLength(1)
    expect(NotificationMock).toHaveBeenCalledOnce()
    expect(NotificationMock).toHaveBeenCalledWith("#elixir", {
      body: "akash: mira: only once",
      tag: "notification:shared",
    })
    firstTab.close()
    secondTab.close()
  })

  test("reports notifications as unsupported when the API is missing", async () => {
    delete window.Notification

    expect(notificationPermission()).toBe("unsupported")
    await expect(requestNotificationPermission()).resolves.toBe("unsupported")
  })
})

function inMemoryBroadcastChannelFactory() {
  const channels = new Map<string, Set<(event: MessageEvent) => void>>()

  return (name: string) => {
    const listeners = channels.get(name) || new Set<(event: MessageEvent) => void>()
    channels.set(name, listeners)

    return {
      addEventListener: (_event: "message", listener: (event: MessageEvent) => void) => {
        listeners.add(listener)
      },
      close: () => undefined,
      postMessage: (data: unknown) => {
        queueMicrotask(() => {
          listeners.forEach((listener) => listener({data} as MessageEvent))
        })
      },
      removeEventListener: (_event: "message", listener: (event: MessageEvent) => void) => {
        listeners.delete(listener)
      },
    }
  }
}
