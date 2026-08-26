import {expect, test, vi} from "vitest"
import {synchronizeServiceWorkerAccount} from "./service_worker_account.ts"

test("reposts the signed-in account when a replacement worker takes control", async () => {
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
    "42",
    serviceWorker as unknown as ServiceWorkerContainer
  )
  await Promise.resolve()

  expect(oldWorker.postMessage).toHaveBeenCalledWith({
    type: "notification:account",
    userId: "42",
  })

  registration.active = nextWorker
  serviceWorker.controller = nextWorker
  controllerChange?.()
  await Promise.resolve()

  expect(nextWorker.postMessage).toHaveBeenCalledWith({
    type: "notification:account",
    userId: "42",
  })

  stop()
  expect(serviceWorker.removeEventListener).toHaveBeenCalledWith(
    "controllerchange",
    controllerChange
  )
})
