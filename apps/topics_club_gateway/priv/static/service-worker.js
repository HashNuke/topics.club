const NOTIFICATION_ICON = "/images/pwa-192.png"
const POSTGRES_BIGINT_MAX = "9223372036854775807"
const NOTIFICATION_ACCOUNT_CACHE = "topics-club-notification-account-v1"
const NOTIFICATION_ACCOUNT_KEY = "/__topics-club-notification-account__"
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
    const payload = notificationPayload(event.data)
    if (!payload) return
    await queueNotificationAccountRefresh()
    if (!await notificationAccountMatches(payload.user_id, payload.session_generation)) return
    if (!await notificationStillEligible(payload)) return

    const windows = await self.clients.matchAll({type: "window", includeUncontrolled: true})
    const visibleChat = windows.some((client) => {
      const pathname = new URL(client.url).pathname
      return client.visibilityState === "visible" &&
        pathname === "/chat" &&
        healthyNotificationClient(client, payload.session_generation)
    })
    if (visibleChat) return

    await self.registration.showNotification(payload.title, {
      body: payload.body,
      icon: NOTIFICATION_ICON,
      badge: NOTIFICATION_ICON,
      tag: payload.tag,
      data: {
        bufferId: payload.buffer_id,
        notificationId: payload.notification_id,
        sessionGeneration: payload.session_generation,
        userId: payload.user_id,
        url: payload.url,
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
  if (typeof clientId !== "string" || clientId.length === 0) return

  if (lease.healthy !== true || !nonemptyString(lease.sessionGeneration)) {
    notificationClientLeases.delete(clientId)
    return
  }

  notificationClientLeases.set(clientId, {
    expiresAt: Date.now() + NOTIFICATION_CLIENT_LEASE_MS,
    sessionGeneration: lease.sessionGeneration,
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
    if (!validPositiveId(account.user_id) || !nonemptyString(account.session_generation)) {
      throw new Error("invalid notification account")
    }
    await storeNotificationAccount(account.user_id, account.session_generation)
  } catch (_error) {
    await storeNotificationAccount(null, null)
  }
}

async function storeNotificationAccount(userId, sessionGeneration) {
  const cache = await caches.open(NOTIFICATION_ACCOUNT_CACHE)
  const normalizedUserId = userId === null ? null : String(userId)
  const normalizedGeneration = sessionGeneration === null ? null : sessionGeneration
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
    !validPositiveId(payloadUserId) ||
    !nonemptyString(payloadSessionGeneration)
  ) return false

  try {
    const cache = await caches.open(NOTIFICATION_ACCOUNT_CACHE)
    const response = await cache.match(NOTIFICATION_ACCOUNT_KEY)
    if (!response) return false
    const account = await response.json()
    return account.userId !== null &&
      account.sessionGeneration !== null &&
      account.userId === String(payloadUserId) &&
      account.sessionGeneration === payloadSessionGeneration
  } catch (_error) {
    return false
  }
}

async function notificationStillEligible(payload) {
  if (!validPositiveId(payload.notification_id) || !nonemptyString(payload.session_generation)) {
    return false
  }

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
    const data = notificationData(event.notification.data)
    if (!data) return
    if (!await notificationAccountMatches(data.userId, data.sessionGeneration)) return
    if (!await notificationStillEligible({
      notification_id: data.notificationId,
      session_generation: data.sessionGeneration,
    })) return

    const targetUrl = data.url
    const windows = await self.clients.matchAll({type: "window", includeUncontrolled: true})
    const existing = windows.find((client) => {
      const pathname = new URL(client.url).pathname
      return pathname === "/chat" &&
        healthyNotificationClient(client, data.sessionGeneration)
    })

    if (existing) {
      existing.postMessage({
        type: "notification:navigate",
        bufferId: data.bufferId,
        sessionGeneration: data.sessionGeneration,
        userId: data.userId,
      })
      await existing.focus()
      return
    }

    await self.clients.openWindow(targetUrl)
  })())
})

function notificationPayload(eventData) {
  let payload

  try {
    payload = eventData?.json?.()
  } catch (_error) {
    return null
  }

  if (
    !payload ||
    typeof payload !== "object" ||
    payload.version !== 1 ||
    !validPositiveId(payload.notification_id) ||
    !validPositiveId(payload.message_id) ||
    !validPositiveId(payload.user_id) ||
    !nonemptyString(payload.session_generation) ||
    !nonemptyString(payload.title) ||
    !nonemptyString(payload.body) ||
    !nonemptyString(payload.tag)
  ) return null

  let expectedTag
  if (payload.type === "notification:mention") {
    if (
      !validPositiveId(payload.channel_membership_id) ||
      payload.buffer_id !== `channel:${payload.channel_membership_id}` ||
      !nonemptyString(payload.channel)
    ) return null
    expectedTag = `notification_mention:message:${payload.message_id}`
  } else if (payload.type === "notification:direct_message") {
    if (
      !validPositiveId(payload.direct_message_thread_id) ||
      payload.buffer_id !== `direct:${payload.direct_message_thread_id}` ||
      !nonemptyString(payload.peer_nick)
    ) return null
    expectedTag = `notification_direct_message:message:${payload.message_id}`
  } else {
    return null
  }

  if (payload.tag !== expectedTag) return null
  const url = notificationUrl(payload.url, payload.buffer_id)
  if (!url) return null

  return {...payload, url}
}

function notificationData(value) {
  if (
    !value ||
    typeof value !== "object" ||
    !validNotificationBufferId(value.bufferId) ||
    !validPositiveId(value.notificationId) ||
    !nonemptyString(value.sessionGeneration) ||
    !validPositiveId(value.userId)
  ) return null

  const url = notificationUrl(value.url, value.bufferId)
  return url ? {...value, url} : null
}

function notificationUrl(value, bufferId) {
  if (!nonemptyString(value) || !validNotificationBufferId(bufferId)) {
    return null
  }

  try {
    const url = new URL(value, self.location.origin)
    const entries = [...url.searchParams.entries()]
    if (
      url.origin !== self.location.origin ||
      url.pathname !== "/chat" ||
      url.hash !== "" ||
      entries.length !== 1 ||
      entries[0][0] !== "buffer" ||
      entries[0][1] !== bufferId
    ) return null

    return new URL(`/chat?buffer=${encodeURIComponent(bufferId)}`, self.location.origin).href
  } catch (_error) {
    return null
  }
}

function validPositiveId(value) {
  if (typeof value === "number") return Number.isSafeInteger(value) && value > 0
  return typeof value === "string" && validPostgresBigint(value)
}

function validNotificationBufferId(value) {
  if (typeof value !== "string") return false
  const match = /^(channel|direct):([1-9][0-9]{0,18})$/.exec(value)
  return Boolean(match && validPostgresBigint(match[2]))
}

function validPostgresBigint(value) {
  if (!/^[1-9][0-9]{0,18}$/.test(value)) return false
  return value.length < POSTGRES_BIGINT_MAX.length ||
    (value.length === POSTGRES_BIGINT_MAX.length && value <= POSTGRES_BIGINT_MAX)
}

function nonemptyString(value) {
  return typeof value === "string" && value.length > 0
}
