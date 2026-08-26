import {afterEach, expect, test, vi} from "vitest"

function directPush(overrides: Record<string, unknown> = {}) {
  return {
    type: "notification:direct_message",
    version: 1,
    title: "Private message",
    body: "akash: hello",
    tag: "notification_direct_message:message:10",
    notification_id: 20,
    message_id: 10,
    user_id: "2",
    session_generation: "session-b",
    direct_message_thread_id: 3,
    peer_nick: "akash",
    buffer_id: "direct:3",
    url: "/app?buffer=direct:3",
    ...overrides,
  }
}

afterEach(() => {
  vi.unstubAllGlobals()
  vi.resetModules()
})

test("ignores a stale tab account during replacement and trusts the server session", async () => {
  const handlers = new Map<string, (event: any) => void>()
  const storedResponses = new Map<string, Response>()
  const showNotification = vi.fn().mockResolvedValue(undefined)
  const oldNotification = {
    data: {sessionGeneration: "session-a"},
    close: vi.fn(),
  }
  const currentNotification = {
    data: {sessionGeneration: "session-b"},
    close: vi.fn(),
  }
  const worker = {
    addEventListener: (type: string, handler: (event: any) => void) => handlers.set(type, handler),
    clients: {
      claim: vi.fn().mockResolvedValue(undefined),
      matchAll: vi.fn().mockResolvedValue([]),
      openWindow: vi.fn(),
    },
    location: {origin: "https://topics.example.test"},
    registration: {
      getNotifications: vi.fn().mockResolvedValue([oldNotification, currentNotification]),
      showNotification,
    },
    skipWaiting: vi.fn(),
  }
  const cache = {
    match: vi.fn(async (key: string) => storedResponses.get(key)?.clone()),
    put: vi.fn(async (key: string, response: Response) => {
      storedResponses.set(key, response.clone())
    }),
  }

  vi.stubGlobal("self", worker)
  vi.stubGlobal("caches", {open: vi.fn().mockResolvedValue(cache)})
  let notificationEligible = true
  let currentAccount: {user_id: string | null; session_generation: string | null} = {
    user_id: "2",
    session_generation: "session-b",
  }
  vi.stubGlobal("fetch", vi.fn().mockImplementation(async (url: string) => {
    const body = url.includes("/eligibility")
      ? {eligible: notificationEligible}
      : currentAccount

    return new Response(JSON.stringify(body), {
      status: 200,
      headers: {"content-type": "application/json"},
    })
  }))

  await import("../../priv/static/service-worker.js")

  await dispatchExtendableEvent(handlers.get("activate"), {})
  expect(worker.clients.claim).toHaveBeenCalledOnce()
  expect(oldNotification.close).toHaveBeenCalled()
  expect(currentNotification.close).not.toHaveBeenCalled()

  await dispatchExtendableEvent(handlers.get("message"), {
    data: {
      type: "notification:refresh-account",
      userId: "stale-account-a",
      sessionGeneration: "stale-session-a",
    },
  })
  expect(fetch).toHaveBeenCalledWith("/api/notification-account", {
    credentials: "include",
    cache: "no-store",
    headers: {accept: "application/json"},
  })
  await dispatchExtendableEvent(handlers.get("push"), {
    data: {json: () => directPush({
      notification_id: 21,
      user_id: "1",
      session_generation: "session-a",
    })},
  })

  expect(showNotification).not.toHaveBeenCalled()

  await dispatchExtendableEvent(handlers.get("push"), {
    data: {json: () => directPush()},
  })

  expect(showNotification).toHaveBeenCalledOnce()

  notificationEligible = false
  await dispatchExtendableEvent(handlers.get("push"), {
    data: {json: () => directPush({
      title: "Delayed private message",
      notification_id: 22,
    })},
  })
  expect(showNotification).toHaveBeenCalledOnce()

  notificationEligible = true
  const visibleClient = {
    id: "visible-chat",
    url: "https://topics.example.test/app",
    visibilityState: "visible",
  }
  worker.clients.matchAll.mockResolvedValue([visibleClient])

  await dispatchExtendableEvent(handlers.get("message"), {
    source: {id: visibleClient.id},
    data: {
      type: "notification:client-lease",
      healthy: true,
      sessionGeneration: "session-a",
    },
  })
  await dispatchExtendableEvent(handlers.get("push"), {
    data: {json: () => directPush({
      title: "New account message",
      notification_id: 23,
    })},
  })
  expect(showNotification).toHaveBeenCalledTimes(2)

  await dispatchExtendableEvent(handlers.get("message"), {
    source: {id: visibleClient.id},
    data: {
      type: "notification:client-lease",
      healthy: false,
      sessionGeneration: "session-b",
    },
  })
  await dispatchExtendableEvent(handlers.get("push"), {
    data: {json: () => directPush({
      title: "Disconnected tab message",
      notification_id: 24,
    })},
  })
  expect(showNotification).toHaveBeenCalledTimes(3)

  await dispatchExtendableEvent(handlers.get("message"), {
    source: {id: visibleClient.id},
    data: {
      type: "notification:client-lease",
      healthy: true,
      sessionGeneration: "session-b",
    },
  })
  await dispatchExtendableEvent(handlers.get("push"), {
    data: {json: () => directPush({
      title: "Healthy tab message",
      notification_id: 25,
    })},
  })
  expect(showNotification).toHaveBeenCalledTimes(3)

  for (let index = 0; index < 40; index += 1) {
    await dispatchExtendableEvent(handlers.get("message"), {
      source: {id: `vanished-${index}`},
      data: {
        type: "notification:client-lease",
        healthy: true,
        sessionGeneration: "session-b",
      },
    })
  }

  worker.clients.matchAll.mockResolvedValue([{
    id: "vanished-0",
    url: "https://topics.example.test/app",
    visibilityState: "visible",
  }])
  await dispatchExtendableEvent(handlers.get("push"), {
    data: {json: () => directPush({
      title: "Lease cap message",
      notification_id: 26,
    })},
  })
  expect(showNotification).toHaveBeenCalledTimes(4)

  await dispatchExtendableEvent(handlers.get("push"), {
    data: {json: () => directPush({url: "https://attacker.example/app"})},
  })
  await dispatchExtendableEvent(handlers.get("push"), {
    data: {json: () => ({...directPush(), type: undefined})},
  })
  expect(showNotification).toHaveBeenCalledTimes(4)

  currentAccount = {user_id: null, session_generation: null}
  await dispatchExtendableEvent(handlers.get("message"), {
    data: {type: "notification:refresh-account"},
  })
  expect(currentNotification.close).toHaveBeenCalled()
})

test("serializes an in-flight stale refresh before checking a new-session push", async () => {
  const handlers = new Map<string, (event: any) => void>()
  const storedResponses = new Map<string, Response>()
  const showNotification = vi.fn().mockResolvedValue(undefined)
  const worker = {
    addEventListener: (type: string, handler: (event: any) => void) => handlers.set(type, handler),
    clients: {
      claim: vi.fn().mockResolvedValue(undefined),
      matchAll: vi.fn().mockResolvedValue([]),
      openWindow: vi.fn(),
    },
    location: {origin: "https://topics.example.test"},
    registration: {
      getNotifications: vi.fn().mockResolvedValue([]),
      showNotification,
    },
    skipWaiting: vi.fn(),
  }
  const cache = {
    match: vi.fn(async (key: string) => storedResponses.get(key)?.clone()),
    put: vi.fn(async (key: string, response: Response) => {
      storedResponses.set(key, response.clone())
    }),
  }
  let resolveStaleRefresh!: (response: Response) => void
  const staleRefresh = new Promise<Response>((resolve) => {
    resolveStaleRefresh = resolve
  })
  let requestCount = 0
  const fetchAccount = vi.fn().mockImplementation(async (url: string) => {
    if (url.includes("/eligibility")) {
      return new Response(JSON.stringify({eligible: true}), {
        status: 200,
        headers: {"content-type": "application/json"},
      })
    }

    requestCount += 1
    if (requestCount === 1) return staleRefresh

    return new Response(JSON.stringify({
      user_id: "2",
      session_generation: "session-b",
    }), {status: 200, headers: {"content-type": "application/json"}})
  })

  vi.stubGlobal("self", worker)
  vi.stubGlobal("caches", {open: vi.fn().mockResolvedValue(cache)})
  vi.stubGlobal("fetch", fetchAccount)
  await import("../../priv/static/service-worker.js")

  const staleRequest = dispatchExtendableEvent(handlers.get("message"), {
    data: {type: "notification:refresh-account"},
  })
  await Promise.resolve()

  const newSessionPush = dispatchExtendableEvent(handlers.get("push"), {
    data: {json: () => directPush()},
  })
  await Promise.resolve()
  expect(fetchAccount).toHaveBeenCalledTimes(1)

  resolveStaleRefresh(new Response(JSON.stringify({
    user_id: "1",
    session_generation: "session-a",
  }), {status: 200, headers: {"content-type": "application/json"}}))

  await staleRequest
  await newSessionPush

  expect(fetchAccount).toHaveBeenCalledTimes(3)
  expect(showNotification).toHaveBeenCalledOnce()
})

async function dispatchExtendableEvent(
  handler: ((event: any) => void) | undefined,
  event: Record<string, unknown>
): Promise<void> {
  expect(handler).toBeTypeOf("function")
  let pending = Promise.resolve()
  handler!({...event, waitUntil: (promise: Promise<unknown>) => { pending = promise.then(() => undefined) }})
  await pending
}
