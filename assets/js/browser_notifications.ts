interface MentionMessage {
  body: string
  channel?: string
  event_id?: string
  nick: string
  peer_nick?: string
}

interface NotificationBroadcastChannel {
  addEventListener(type: "message", listener: (event: MessageEvent) => void): void
  close(): void
  postMessage(message: unknown): void
  removeEventListener(type: "message", listener: (event: MessageEvent) => void): void
}

interface NotificationClaimStorage {
  getItem(key: string): string | null
  setItem(key: string, value: string): void
}

interface NotificationEventCoordinatorOptions {
  channelFactory?: (name: string) => NotificationBroadcastChannel | null
  claimWindowMs?: number
  scope?: string
  storage?: NotificationClaimStorage | null
  tabId?: string
}

export interface NotificationEventCoordinator {
  claim(eventId: string): Promise<boolean>
  close(): void
}

interface CoordinationMessage {
  event_id: string
  tab_id: string
  type: "claim" | "shown"
}

interface StoredClaim {
  claimed_at: number
  tab_id: string
}

export type BrowserNotificationState = NotificationPermission | "unsupported" | "insecure"

export interface NotificationDeviceState {
  capability: BrowserNotificationState
  configured: boolean
  error?: string | null
  loading: boolean
  subscribed: boolean
}

interface MentionNotificationOptions {
  currentUser?: {email?: string} | null
  notificationState: BrowserNotificationState
}

const CLAIM_LIMIT = 500
const CLAIM_TTL_MS = 10 * 60 * 1_000
const DEFAULT_CLAIM_WINDOW_MS = 25
const STORAGE_PREFIX = "ircpipe.notification-claims.v1"

export function createNotificationEventCoordinator(
  options: NotificationEventCoordinatorOptions = {}
): NotificationEventCoordinator {
  const scope = String(options.scope || "default").slice(0, 128)
  const tabId = options.tabId || uniqueTabId()
  const claimWindowMs = Math.max(0, options.claimWindowMs ?? DEFAULT_CLAIM_WINDOW_MS)
  const storage = options.storage === undefined ? availableLocalStorage() : options.storage
  const storageKey = `${STORAGE_PREFIX}:${scope}`
  const channelFactory = options.channelFactory || defaultChannelFactory
  const channel = channelFactory(`${STORAGE_PREFIX}:${scope}`)
  const attempted = new Set<string>()
  const shown = new Set<string>()
  const claimants = new Map<string, Set<string>>()
  let closed = false

  const onMessage = (event: MessageEvent) => {
    const message = coordinationMessage(event.data)
    if (!message) return

    if (message.type === "shown") {
      rememberBounded(shown, message.event_id)
      claimants.delete(message.event_id)
      return
    }

    if (shown.has(message.event_id)) return
    const eventClaimants = claimants.get(message.event_id) || new Set<string>()
    eventClaimants.add(message.tab_id)
    claimants.set(message.event_id, eventClaimants)
  }

  channel?.addEventListener("message", onMessage)

  return {
    async claim(rawEventId: string): Promise<boolean> {
      if (closed) return false
      const eventId = normalizedEventId(rawEventId)
      if (!eventId) return true
      if (attempted.has(eventId) || shown.has(eventId) || storedClaim(storage, storageKey, eventId)) {
        return false
      }

      rememberBounded(attempted, eventId)
      const eventClaimants = claimants.get(eventId) || new Set<string>()
      eventClaimants.add(tabId)
      claimants.set(eventId, eventClaimants)
      channel?.postMessage({type: "claim", event_id: eventId, tab_id: tabId} satisfies CoordinationMessage)

      if (channel) await delay(claimWindowMs)
      if (closed || shown.has(eventId)) return false

      const winner = [...(claimants.get(eventId) || [])].sort()[0]
      if (winner !== tabId) return false
      if (!storeClaim(storage, storageKey, eventId, tabId)) return false

      rememberBounded(shown, eventId)
      claimants.delete(eventId)
      channel?.postMessage({type: "shown", event_id: eventId, tab_id: tabId} satisfies CoordinationMessage)
      return true
    },

    close(): void {
      closed = true
      channel?.removeEventListener("message", onMessage)
      channel?.close()
    },
  }
}

export function notificationPermission(): BrowserNotificationState {
  if (window.isSecureContext === false) return "insecure"
  if (!("Notification" in window)) return "unsupported"
  return window.Notification.permission
}

export function initialNotificationDeviceState(): NotificationDeviceState {
  return {
    capability: notificationPermission(),
    configured: false,
    loading: true,
    subscribed: false,
  }
}

export function notificationUnavailableReason(state: NotificationDeviceState): string | null {
  if (!state.configured) return "Push notifications are not configured on this server."
  if (state.capability === "insecure") return "Notifications require HTTPS or localhost."
  if (state.capability === "unsupported") return "This browser or installation does not support Web Push."
  if (state.capability === "denied") return "Notifications are blocked in browser or operating-system settings."
  return null
}

export async function requestNotificationPermission(): Promise<BrowserNotificationState> {
  const state = notificationPermission()
  if (state === "insecure" || state === "unsupported" || state === "denied") return state
  return window.Notification.requestPermission()
}

export function showMentionNotification(
  message: MentionMessage,
  {currentUser, notificationState}: MentionNotificationOptions
): boolean {
  if (window.isSecureContext === false) return false
  if (!("Notification" in window)) return false
  if (document.visibilityState !== "hidden") return false
  if (notificationState !== "granted" && window.Notification.permission !== "granted") return false
  if (message.nick === currentUser?.email?.split("@")[0]) return false

  const options: NotificationOptions = {
    body: `${message.nick}: ${message.body}`,
  }
  if (message.event_id) options.tag = normalizedEventId(message.event_id)

  new window.Notification(message.channel || message.peer_nick || "topics.club", options)
  return true
}

function defaultChannelFactory(name: string): NotificationBroadcastChannel | null {
  try {
    if (typeof window.BroadcastChannel !== "function") return null
    return new window.BroadcastChannel(name)
  } catch (_error) {
    return null
  }
}

function availableLocalStorage(): NotificationClaimStorage | null {
  try {
    return window.localStorage
  } catch (_error) {
    return null
  }
}

function storedClaim(
  storage: NotificationClaimStorage | null,
  storageKey: string,
  eventId: string
): StoredClaim | null {
  const claims = storedClaims(storage, storageKey)
  return claims[eventId] || null
}

function storeClaim(
  storage: NotificationClaimStorage | null,
  storageKey: string,
  eventId: string,
  tabId: string
): boolean {
  if (!storage) return true

  try {
    const claims = storedClaims(storage, storageKey)
    if (claims[eventId]) return false
    claims[eventId] = {claimed_at: Date.now(), tab_id: tabId}

    const boundedClaims = Object.fromEntries(
      Object.entries(claims)
        .sort(([, left], [, right]) => right.claimed_at - left.claimed_at)
        .slice(0, CLAIM_LIMIT)
    )
    storage.setItem(storageKey, JSON.stringify(boundedClaims))
    return storedClaims(storage, storageKey)[eventId]?.tab_id === tabId
  } catch (_error) {
    return true
  }
}

function storedClaims(
  storage: NotificationClaimStorage | null,
  storageKey: string
): Record<string, StoredClaim> {
  if (!storage) return {}

  try {
    const parsed = JSON.parse(storage.getItem(storageKey) || "{}")
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return {}
    const cutoff = Date.now() - CLAIM_TTL_MS

    return Object.fromEntries(
      Object.entries(parsed).filter((entry): entry is [string, StoredClaim] => {
        const claim = entry[1] as Partial<StoredClaim> | null
        return Boolean(
          claim &&
          typeof claim.claimed_at === "number" &&
          claim.claimed_at >= cutoff &&
          typeof claim.tab_id === "string"
        )
      })
    )
  } catch (_error) {
    return {}
  }
}

function coordinationMessage(value: unknown): CoordinationMessage | null {
  if (!value || typeof value !== "object") return null
  const message = value as Partial<CoordinationMessage>
  const eventId = normalizedEventId(message.event_id)

  if (!eventId || !message.tab_id || !["claim", "shown"].includes(message.type || "")) {
    return null
  }

  return {event_id: eventId, tab_id: String(message.tab_id), type: message.type!}
}

function normalizedEventId(value: unknown): string {
  return typeof value === "string" ? value.trim().slice(0, 256) : ""
}

function rememberBounded(values: Set<string>, value: string): void {
  values.add(value)
  if (values.size <= CLAIM_LIMIT) return
  const oldest = values.values().next().value
  if (oldest) values.delete(oldest)
}

function uniqueTabId(): string {
  return globalThis.crypto?.randomUUID?.() || `tab-${Date.now()}-${Math.random().toString(36).slice(2)}`
}

function delay(milliseconds: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, milliseconds))
}
