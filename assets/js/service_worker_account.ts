export function synchronizeServiceWorkerAccount(
  serviceWorker: ServiceWorkerContainer = navigator.serviceWorker
): () => void {
  let disposed = false

  const postAccount = () => {
    serviceWorker.ready
      .then((registration) => {
        if (disposed) return

        const workers = new Set<ServiceWorker>()
        if (registration.active) workers.add(registration.active)
        if (registration.waiting) workers.add(registration.waiting)
        if (registration.installing) workers.add(registration.installing)
        if (serviceWorker.controller) workers.add(serviceWorker.controller)

        for (const worker of workers) {
          worker.postMessage({type: "notification:refresh-account"})
        }
      })
      .catch(() => undefined)
  }

  postAccount()
  serviceWorker.addEventListener("controllerchange", postAccount)

  return () => {
    disposed = true
    serviceWorker.removeEventListener("controllerchange", postAccount)
  }
}

interface ClientLease {
  healthy: boolean
  sessionGeneration: string | null
}

export function synchronizeServiceWorkerClientLease(
  lease: ClientLease,
  serviceWorker: ServiceWorkerContainer = navigator.serviceWorker
): () => void {
  let disposed = false

  const postLease = (healthy = lease.healthy) => {
    serviceWorker.ready
      .then((registration) => {
        if (disposed && healthy) return

        const workers = new Set<ServiceWorker>()
        if (registration.active) workers.add(registration.active)
        if (registration.waiting) workers.add(registration.waiting)
        if (registration.installing) workers.add(registration.installing)
        if (serviceWorker.controller) workers.add(serviceWorker.controller)

        for (const worker of workers) {
          worker.postMessage({
            type: "notification:client-lease",
            healthy,
            sessionGeneration: lease.sessionGeneration,
          })
        }
      })
      .catch(() => undefined)
  }

  const renewLease = () => postLease()
  postLease()
  const heartbeat = window.setInterval(renewLease, 15_000)
  serviceWorker.addEventListener("controllerchange", renewLease)

  return () => {
    window.clearInterval(heartbeat)
    serviceWorker.removeEventListener("controllerchange", renewLease)
    postLease(false)
    disposed = true
  }
}
