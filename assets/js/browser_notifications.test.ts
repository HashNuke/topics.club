import {afterEach, describe, expect, test, vi} from "vitest"
import {
  createNotificationEventCoordinator,
  notificationPermission,
  requestNotificationPermission,
  showMentionNotification,
} from "./browser_notifications.ts"
import type {ChannelNotificationEventPayload, DirectMessageNotificationEventPayload} from "./types.ts"

function channelNotification(
  overrides: Partial<ChannelNotificationEventPayload> = {}
): ChannelNotificationEventPayload {
  return {
    type: "notification:mention",
    version: 1,
    event_id: "notification:akash",
    id: 10,
    notification_id: 20,
    server_connection_id: 1,
    channel_membership_id: 2,
    buffer_id: "channel:2",
    nick: "akash",
    channel: "#elixir",
    body: "mira: ping",
    ...overrides,
  }
}

function directNotification(
  overrides: Partial<DirectMessageNotificationEventPayload> = {}
): DirectMessageNotificationEventPayload {
  return {
    type: "notification:direct_message",
    version: 1,
    event_id: "notification:direct",
    id: 11,
    notification_id: 21,
    server_connection_id: 1,
    direct_message_thread_id: 3,
    buffer_id: "direct:3",
    nick: "akash",
    peer_nick: "akash",
    body: "hello privately",
    ...overrides,
  }
}

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
      channelNotification(),
      {notificationState: "granted"}
    )).toBe(true)
    expect(NotificationMock).toHaveBeenCalledWith("#elixir", {
      body: "akash: mira: ping",
      tag: "notification:akash",
    })

    expect(showMentionNotification(
      channelNotification({event_id: "notification:mira", nick: "mira", body: "legitimate sender matching email prefix"}),
      {notificationState: "granted"}
    )).toBe(true)
    expect(NotificationMock).toHaveBeenCalledTimes(2)
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
      channelNotification({event_id: "notification:insecure"}),
      {notificationState: "insecure"}
    )).toBe(false)
  })

  test("uses the peer nick as the title for a direct message", () => {
    const NotificationMock = vi.fn()
    NotificationMock.permission = "granted"
    Object.defineProperty(window, "Notification", {value: NotificationMock, configurable: true})
    Object.defineProperty(document, "visibilityState", {value: "hidden", configurable: true})

    expect(showMentionNotification(
      directNotification(),
      {notificationState: "granted"}
    )).toBe(true)
    expect(NotificationMock).toHaveBeenCalledWith("akash", {
      body: "akash: hello privately",
      tag: "notification:direct",
    })
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
    const message = channelNotification({
      event_id: "notification:shared",
      body: "mira: only once",
    })

    const displays = await Promise.all([
      firstTab.coordinate(message.event_id, {
        eligible: true,
        visible: false,
        display: () =>
          showMentionNotification(message, {
            notificationState: "granted",
          }),
      }),
      secondTab.coordinate(message.event_id, {
        eligible: true,
        visible: false,
        display: () =>
          showMentionNotification(message, {
            notificationState: "granted",
          }),
      }),
    ])

    expect(NotificationMock).toHaveBeenCalledOnce()
    expect(displays.filter(Boolean)).toHaveLength(1)
    expect(NotificationMock).toHaveBeenCalledWith("#elixir", {
      body: "akash: mira: only once",
      tag: "notification:shared",
    })
    firstTab.close()
    secondTab.close()
  })

  test("completes slow tab authorization before entering the synchronous election", async () => {
    const channelFactory = inMemoryBroadcastChannelFactory()
    const display = vi.fn().mockReturnValue(true)
    const firstTab = createNotificationEventCoordinator({
      channelFactory,
      claimWindowMs: 1,
      scope: "slow-authorization",
      storage: null,
      tabId: "tab-a",
    })
    const secondTab = createNotificationEventCoordinator({
      channelFactory,
      claimWindowMs: 1,
      scope: "slow-authorization",
      storage: null,
      tabId: "tab-b",
    })

    const authorizeThenCoordinate = async (
      coordinator: ReturnType<typeof createNotificationEventCoordinator>,
      authorizationDelay: number
    ) => {
      await new Promise((resolve) => setTimeout(resolve, authorizationDelay))
      return coordinator.coordinate("notification:slow-authorization", {
        eligible: true,
        visible: false,
        display,
      })
    }

    const outcomes = await Promise.all([
      authorizeThenCoordinate(firstTab, 5),
      authorizeThenCoordinate(secondTab, 30),
    ])

    expect(display).toHaveBeenCalledOnce()
    expect(outcomes.filter(Boolean)).toHaveLength(1)
    firstTab.close()
    secondTab.close()
  })

  test("a visible tab suppresses fallback notifications in every tab", async () => {
    const channelFactory = inMemoryBroadcastChannelFactory()
    const visibleDisplay = vi.fn().mockReturnValue(true)
    const hiddenDisplay = vi.fn().mockReturnValue(true)
    const visibleTab = createNotificationEventCoordinator({
      channelFactory,
      claimWindowMs: 1,
      scope: "user-visible",
      storage: null,
      tabId: "tab-visible",
    })
    const hiddenTab = createNotificationEventCoordinator({
      channelFactory,
      claimWindowMs: 1,
      scope: "user-visible",
      storage: null,
      tabId: "tab-hidden",
    })

    const outcomes = await Promise.all([
      visibleTab.coordinate("notification:mixed-visibility", {
        eligible: false,
        visible: true,
        display: visibleDisplay,
      }),
      hiddenTab.coordinate("notification:mixed-visibility", {
        eligible: true,
        visible: false,
        display: hiddenDisplay,
      }),
    ])

    expect(outcomes).toEqual([false, false])
    expect(visibleDisplay).not.toHaveBeenCalled()
    expect(hiddenDisplay).not.toHaveBeenCalled()
    visibleTab.close()
    hiddenTab.close()
  })

  test("a failed constructor releases ownership to another eligible hidden tab", async () => {
    let constructorCalls = 0
    const NotificationMock = vi.fn(function () {
      constructorCalls += 1

      if (constructorCalls === 1) {
        throw new Error("Notification constructor failed")
      }
    })
    NotificationMock.permission = "granted"
    Object.defineProperty(window, "Notification", {value: NotificationMock, configurable: true})
    Object.defineProperty(document, "visibilityState", {value: "hidden", configurable: true})
    const channelFactory = inMemoryBroadcastChannelFactory()
    const message = channelNotification({
      event_id: "notification:constructor-failure",
      body: "mira: fail over",
    })
    const display = () =>
      showMentionNotification(message, {
        notificationState: "granted",
      })
    const firstTab = createNotificationEventCoordinator({
      channelFactory,
      claimWindowMs: 1,
      scope: "user-failover",
      storage: null,
      tabId: "tab-a",
    })
    const secondTab = createNotificationEventCoordinator({
      channelFactory,
      claimWindowMs: 1,
      scope: "user-failover",
      storage: null,
      tabId: "tab-b",
    })

    const outcomes = await Promise.all([
      firstTab.coordinate("notification:constructor-failure", {
        eligible: true,
        visible: false,
        display,
      }),
      secondTab.coordinate("notification:constructor-failure", {
        eligible: true,
        visible: false,
        display,
      }),
    ])

    expect(outcomes).toEqual([false, true])
    expect(NotificationMock).toHaveBeenCalledTimes(2)
    firstTab.close()
    secondTab.close()
  })

  test("fails closed when BroadcastChannel coordination is unavailable", async () => {
    const display = vi.fn().mockReturnValue(true)
    const coordinator = createNotificationEventCoordinator({
      channelFactory: () => null,
      claimWindowMs: 1,
      scope: "no-fallback",
      storage: inMemoryClaimStorage(),
      tabId: "tab-a",
    })

    await expect(coordinator.coordinate("notification:no-channel", {
      eligible: true,
      visible: false,
      display,
    })).resolves.toBe(false)

    expect(display).not.toHaveBeenCalled()
    coordinator.close()
  })

  test("fails closed for missing or malformed event IDs", async () => {
    const display = vi.fn().mockReturnValue(true)
    const coordinator = createNotificationEventCoordinator({
      channelFactory: inMemoryBroadcastChannelFactory(),
      claimWindowMs: 1,
      scope: "strict-events",
      storage: null,
      tabId: "tab-a",
    })

    await expect(coordinator.coordinate("", {
      eligible: true,
      visible: false,
      display,
    })).resolves.toBe(false)
    await expect(coordinator.coordinate("x".repeat(257), {
      eligible: true,
      visible: false,
      display,
    })).resolves.toBe(false)

    expect(display).not.toHaveBeenCalled()
    coordinator.close()
  })

  test("ignores malformed coordination candidates and stored outcomes", async () => {
    const display = vi.fn().mockReturnValue(true)
    const storageKey = "ircpipe.notification-claims.v1:strict-coordination"
    const values = new Map<string, string>([[
      storageKey,
      JSON.stringify({
        "notification:strict-coordination": {
          claimed_at: Date.now(),
          outcome: "legacy-default",
          tab_id: "tab-stale",
        },
      }),
    ]])
    const storage = {
      getItem: (key: string) => values.get(key) || null,
      setItem: (key: string, value: string) => values.set(key, value),
    }
    const network = controllableBroadcastChannelFactory()
    const coordinator = createNotificationEventCoordinator({
      channelFactory: network.factory,
      claimWindowMs: 1,
      scope: "strict-coordination",
      storage,
      tabId: "tab-a",
    })

    network.post("ircpipe.notification-claims.v1:strict-coordination", {
      type: "candidate",
      event_id: "notification:strict-coordination",
      tab_id: "tab-malformed",
      eligible: "true",
      visible: "true",
    })

    await expect(coordinator.coordinate("notification:strict-coordination", {
      eligible: true,
      visible: false,
      display,
    })).resolves.toBe(true)

    expect(display).toHaveBeenCalledOnce()
    coordinator.close()
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

function controllableBroadcastChannelFactory() {
  const channels = new Map<string, Set<(event: MessageEvent) => void>>()

  return {
    factory: (name: string) => {
      const listeners = channels.get(name) || new Set<(event: MessageEvent) => void>()
      channels.set(name, listeners)

      return {
        addEventListener: (_event: "message", listener: (event: MessageEvent) => void) => listeners.add(listener),
        close: () => undefined,
        postMessage: (data: unknown) => queueMicrotask(() => {
          listeners.forEach((listener) => listener({data} as MessageEvent))
        }),
        removeEventListener: (_event: "message", listener: (event: MessageEvent) => void) => listeners.delete(listener),
      }
    },
    post: (name: string, data: unknown) => {
      channels.get(name)?.forEach((listener) => listener({data} as MessageEvent))
    },
  }
}

function inMemoryClaimStorage() {
  const values = new Map<string, string>()

  return {
    getItem: (key: string) => values.get(key) || null,
    setItem: (key: string, value: string) => values.set(key, value),
  }
}
