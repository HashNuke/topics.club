const NOTIFICATION_ICON = "/images/pwa-192.png"
const NOTIFICATION_ACCOUNT_CACHE = "ircpipe-notification-account-v1"
const NOTIFICATION_ACCOUNT_KEY = "/__ircpipe-notification-account__"

self.addEventListener("install", () => self.skipWaiting())
self.addEventListener("activate", (event) => event.waitUntil(self.clients.claim()))

self.addEventListener("message", (event) => {
  if (event.data?.type !== "notification:account") return
  event.waitUntil(storeNotificationAccount(event.data.userId))
})

self.addEventListener("push", (event) => {
  event.waitUntil((async () => {
    const payload = event.data?.json?.() || {}
    if (!await notificationAccountMatches(payload.user_id)) return

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

async function storeNotificationAccount(userId) {
  const cache = await caches.open(NOTIFICATION_ACCOUNT_CACHE)
  await cache.put(
    NOTIFICATION_ACCOUNT_KEY,
    new Response(JSON.stringify({userId: userId === null ? null : String(userId)}), {
      headers: {"content-type": "application/json"},
    })
  )
}

async function notificationAccountMatches(payloadUserId) {
  if (payloadUserId === undefined || payloadUserId === null) return false

  try {
    const cache = await caches.open(NOTIFICATION_ACCOUNT_CACHE)
    const response = await cache.match(NOTIFICATION_ACCOUNT_KEY)
    if (!response) return false
    const account = await response.json()
    return account.userId !== null && String(account.userId) === String(payloadUserId)
  } catch (_error) {
    return false
  }
}

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
