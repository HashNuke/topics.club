import {expect, test, vi} from "vitest"
import {
  synchronizeServiceWorkerAccount,
  synchronizeServiceWorkerClientLease,
} from "./service_worker_account.ts"

test("asks a replacement worker to refresh the server-authenticated account", async () => {
  let controllerChange: (() => void) | undefined
  const oldWorker = {postMessage: vi.fn()}
  const nextWorker = {postMessage: vi.fn()}
  const registration = {active: oldWorker, waiting: null, installing: null}
  const serviceWorker = {
    controller: oldWorker,
    ready: Promise.resolve(registration),
    addEventListener: vi.fn((type: string, listener: () => void) => {
      if (type === "controllerchange") controllerChange = listener
    }),
    removeEventListener: vi.fn(),
  }

  const stop = synchronizeServiceWorkerAccount(
    serviceWorker as unknown as ServiceWorkerContainer
  )
  await Promise.resolve()

  expect(oldWorker.postMessage).toHaveBeenCalledWith({
    type: "notification:refresh-account",
  })

  registration.active = nextWorker
  serviceWorker.controller = nextWorker
  controllerChange?.()
  await Promise.resolve()

  expect(nextWorker.postMessage).toHaveBeenCalledWith({
    type: "notification:refresh-account",
  })

  stop()
  expect(serviceWorker.removeEventListener).toHaveBeenCalledWith(
    "controllerchange",
    controllerChange
  )
})

test("publishes and revokes a bounded healthy-client lease", async () => {
  const worker = {postMessage: vi.fn()}
  const registration = {active: worker, waiting: null, installing: null}
  const serviceWorker = {
    controller: worker,
    ready: Promise.resolve(registration),
    addEventListener: vi.fn(),
    removeEventListener: vi.fn(),
  }

  const stop = synchronizeServiceWorkerClientLease(
    {healthy: true, sessionGeneration: "session-b"},
    serviceWorker as unknown as ServiceWorkerContainer
  )
  await Promise.resolve()

  expect(worker.postMessage).toHaveBeenCalledWith({
    type: "notification:client-lease",
    healthy: true,
    sessionGeneration: "session-b",
  })

  stop()
  await Promise.resolve()

  expect(worker.postMessage).toHaveBeenCalledWith({
    type: "notification:client-lease",
    healthy: false,
    sessionGeneration: "session-b",
  })
})
