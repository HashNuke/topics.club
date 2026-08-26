const NOTIFICATION_ICON = "/images/pwa-192.png"
const NOTIFICATION_ACCOUNT_CACHE = "ircpipe-notification-account-v1"
const NOTIFICATION_ACCOUNT_KEY = "/__ircpipe-notification-account__"
let notificationAccountRefresh = Promise.resolve()
const notificationClientLeases = new Map()
const NOTIFICATION_CLIENT_LEASE_MS = 30_000
const NOTIFICATION_CLIENT_LEASE_LIMIT = 32

self.addEventListener("install", () => self.skipWaiting())
self.addEventListener("activate", (event) => {
  event.waitUntil(Promise.all([self.clients.claim(), queueNotificationAccountRefresh()]))
})

self.addEventListener("message", (event) => {
  if (event.data?.type === "notification:refresh-account") {
    event.waitUntil(queueNotificationAccountRefresh())
    return
  }

  if (event.data?.type === "notification:client-lease") {
    updateNotificationClientLease(event.source?.id, event.data)
  }
})

self.addEventListener("push", (event) => {
  event.waitUntil((async () => {
    pruneNotificationClientLeases()
    const payload = event.data?.json?.() || {}
    await queueNotificationAccountRefresh()
    if (!await notificationAccountMatches(payload.user_id, payload.session_generation)) return
    if (!await notificationStillEligible(payload)) return

    const windows = await self.clients.matchAll({type: "window", includeUncontrolled: true})
    const visibleChat = windows.some((client) => {
      const pathname = new URL(client.url).pathname
      return client.visibilityState === "visible" &&
        (pathname === "/app" || pathname === "/chat") &&
        healthyNotificationClient(client, payload.session_generation)
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
        sessionGeneration: payload.session_generation,
        userId: payload.user_id,
        url: payload.url || "/app",
      },
    })
  })())
})

function queueNotificationAccountRefresh() {
  notificationAccountRefresh = notificationAccountRefresh
    .catch(() => undefined)
    .then(() => refreshNotificationAccount())

  return notificationAccountRefresh
}

function updateNotificationClientLease(clientId, lease) {
  pruneNotificationClientLeases()
  if (!clientId) return

  if (!lease.healthy || !lease.sessionGeneration) {
    notificationClientLeases.delete(clientId)
    return
  }

  notificationClientLeases.set(clientId, {
    expiresAt: Date.now() + NOTIFICATION_CLIENT_LEASE_MS,
    sessionGeneration: String(lease.sessionGeneration),
  })

  while (notificationClientLeases.size > NOTIFICATION_CLIENT_LEASE_LIMIT) {
    const oldestClientId = [...notificationClientLeases.entries()]
      .sort((left, right) => left[1].expiresAt - right[1].expiresAt)[0]?.[0]
    if (!oldestClientId) break
    notificationClientLeases.delete(oldestClientId)
  }
}

function pruneNotificationClientLeases() {
  const now = Date.now()
  for (const [clientId, lease] of notificationClientLeases) {
    if (lease.expiresAt <= now) notificationClientLeases.delete(clientId)
  }
}

function healthyNotificationClient(client, sessionGeneration) {
  const lease = notificationClientLeases.get(client.id)
  if (!lease) return false
  if (lease.expiresAt <= Date.now()) {
    notificationClientLeases.delete(client.id)
    return false
  }

  return lease.sessionGeneration === String(sessionGeneration)
}

async function refreshNotificationAccount() {
  try {
    const response = await fetch("/api/notification-account", {
      credentials: "include",
      cache: "no-store",
      headers: {accept: "application/json"},
    })
    if (!response.ok) throw new Error("notification account request failed")
    const account = await response.json()
    await storeNotificationAccount(account.user_id, account.session_generation)
  } catch (_error) {
    await storeNotificationAccount(null, null)
  }
}

async function storeNotificationAccount(userId, sessionGeneration) {
  const cache = await caches.open(NOTIFICATION_ACCOUNT_CACHE)
  const normalizedUserId = userId === null ? null : String(userId)
  const normalizedGeneration = sessionGeneration === null ? null : String(sessionGeneration)
  await cache.put(
    NOTIFICATION_ACCOUNT_KEY,
    new Response(JSON.stringify({
      userId: normalizedUserId,
      sessionGeneration: normalizedGeneration,
    }), {
      headers: {"content-type": "application/json"},
    })
  )

  await closeNotificationsOutsideGeneration(normalizedGeneration)
}

async function closeNotificationsOutsideGeneration(currentGeneration) {
  const notifications = await self.registration.getNotifications()
  for (const notification of notifications) {
    if (!currentGeneration || notification.data?.sessionGeneration !== currentGeneration) {
      notification.close()
    }
  }
}

async function notificationAccountMatches(payloadUserId, payloadSessionGeneration) {
  if (
    payloadUserId === undefined ||
    payloadUserId === null ||
    payloadSessionGeneration === undefined ||
    payloadSessionGeneration === null
  ) return false

  try {
    const cache = await caches.open(NOTIFICATION_ACCOUNT_CACHE)
    const response = await cache.match(NOTIFICATION_ACCOUNT_KEY)
    if (!response) return false
    const account = await response.json()
    return account.userId !== null &&
      account.sessionGeneration !== null &&
      String(account.userId) === String(payloadUserId) &&
      String(account.sessionGeneration) === String(payloadSessionGeneration)
  } catch (_error) {
    return false
  }
}

async function notificationStillEligible(payload) {
  if (!payload.notification_id || !payload.session_generation) return false

  try {
    const query = new URLSearchParams({session_generation: String(payload.session_generation)})
    const response = await fetch(
      `/api/notifications/${encodeURIComponent(payload.notification_id)}/eligibility?${query}`,
      {
        credentials: "include",
        cache: "no-store",
        headers: {accept: "application/json"},
      }
    )
    if (!response.ok) return false
    const result = await response.json()
    return result.eligible === true
  } catch (_error) {
    return false
  }
}

self.addEventListener("notificationclick", (event) => {
  event.notification.close()
  event.waitUntil((async () => {
    pruneNotificationClientLeases()
    await queueNotificationAccountRefresh()
    const data = event.notification.data || {}
    if (!await notificationAccountMatches(data.userId, data.sessionGeneration)) return
    if (!await notificationStillEligible({
      notification_id: data.notificationId,
      session_generation: data.sessionGeneration,
    })) return

    const targetUrl = new URL(event.notification.data?.url || "/app", self.location.origin).href
    const windows = await self.clients.matchAll({type: "window", includeUncontrolled: true})
    const existing = windows.find((client) => {
      const pathname = new URL(client.url).pathname
      return (pathname === "/app" || pathname === "/chat") &&
        healthyNotificationClient(client, data.sessionGeneration)
    })

    if (existing) {
      existing.postMessage({type: "notification:navigate", bufferId: event.notification.data?.bufferId})
      await existing.focus()
      return
    }

    await self.clients.openWindow(targetUrl)
  })())
})
