import {afterEach, expect, test, vi} from "vitest"

afterEach(() => {
  vi.unstubAllGlobals()
  vi.resetModules()
})

test("ignores a stale tab account during replacement and trusts the server session", async () => {
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
    registration: {showNotification},
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
  vi.stubGlobal("fetch", vi.fn().mockImplementation(async () =>
    new Response(JSON.stringify({
      user_id: "account-b",
      session_generation: "session-b",
    }), {status: 200, headers: {"content-type": "application/json"}})
  ))

  await import("../../priv/static/service-worker.js")

  await dispatchExtendableEvent(handlers.get("activate"), {})
  expect(worker.clients.claim).toHaveBeenCalledOnce()

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
    data: {json: () => ({
      title: "Private message",
      user_id: "account-a",
      session_generation: "session-a",
    })},
  })

  expect(showNotification).not.toHaveBeenCalled()

  await dispatchExtendableEvent(handlers.get("push"), {
    data: {json: () => ({
      title: "Private message",
      user_id: "account-b",
      session_generation: "session-b",
    })},
  })

  expect(showNotification).toHaveBeenCalledOnce()
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
    registration: {showNotification},
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
  const fetchAccount = vi.fn().mockImplementation(async () => {
    requestCount += 1
    if (requestCount === 1) return staleRefresh

    return new Response(JSON.stringify({
      user_id: "account-b",
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
    data: {json: () => ({
      title: "Private message",
      user_id: "account-b",
      session_generation: "session-b",
    })},
  })
  await Promise.resolve()
  expect(fetchAccount).toHaveBeenCalledTimes(1)

  resolveStaleRefresh(new Response(JSON.stringify({
    user_id: "account-a",
    session_generation: "session-a",
  }), {status: 200, headers: {"content-type": "application/json"}}))

  await staleRequest
  await newSessionPush

  expect(fetchAccount).toHaveBeenCalledTimes(2)
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
