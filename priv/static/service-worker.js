const NOTIFICATION_ICON = "/images/pwa-192.png"

self.addEventListener("install", () => self.skipWaiting())
self.addEventListener("activate", (event) => event.waitUntil(self.clients.claim()))

self.addEventListener("push", (event) => {
  event.waitUntil((async () => {
    const payload = event.data?.json?.() || {}
    const windows = await self.clients.matchAll({type: "window", includeUncontrolled: true})
    const visibleChat = windows.some((client) => {
      const pathname = new URL(client.url).pathname
      return client.visibilityState === "visible" && (pathname === "/app" || pathname === "/chat")
    })
    if (visibleChat) return

    await self.registration.showNotification(payload.title || "topics.club mention", {
      body: payload.body || "You were mentioned in a channel.",
      icon: NOTIFICATION_ICON,
      badge: NOTIFICATION_ICON,
      tag: payload.tag || `mention:${payload.notification_id || Date.now()}`,
      data: {
        bufferId: payload.buffer_id,
        notificationId: payload.notification_id,
        url: payload.url || "/app",
      },
    })
  })())
})

self.addEventListener("notificationclick", (event) => {
  event.notification.close()
  event.waitUntil((async () => {
    const targetUrl = new URL(event.notification.data?.url || "/app", self.location.origin).href
    const windows = await self.clients.matchAll({type: "window", includeUncontrolled: true})
    const existing = windows.find((client) => {
      const pathname = new URL(client.url).pathname
      return pathname === "/app" || pathname === "/chat"
    })

    if (existing) {
      existing.postMessage({type: "notification:navigate", bufferId: event.notification.data?.bufferId})
      await existing.focus()
      return
    }

    await self.clients.openWindow(targetUrl)
  })())
})
