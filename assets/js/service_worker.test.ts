import {afterEach, expect, test, vi} from "vitest"

afterEach(() => {
  vi.unstubAllGlobals()
  vi.resetModules()
})

test("suppresses push payloads for a different signed-in account", async () => {
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

  await import("../../priv/static/service-worker.js")

  await dispatchExtendableEvent(handlers.get("message"), {
    data: {type: "notification:account", userId: "account-b"},
  })
  await dispatchExtendableEvent(handlers.get("push"), {
    data: {json: () => ({title: "Private message", user_id: "account-a"})},
  })

  expect(showNotification).not.toHaveBeenCalled()

  await dispatchExtendableEvent(handlers.get("push"), {
    data: {json: () => ({title: "Private message", user_id: "account-b"})},
  })

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
