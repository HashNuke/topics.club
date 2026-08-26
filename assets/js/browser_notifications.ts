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
  coordinate(eventId: string, candidate: NotificationDisplayCandidate): Promise<boolean>
  close(): void
}

interface NotificationDisplayCandidate {
  display(): boolean
  eligible: boolean
  visible: boolean
}

interface CoordinationMessage {
  eligible?: boolean
  event_id: string
  tab_id: string
  type: "candidate" | "failed" | "shown" | "suppressed"
  visible?: boolean
}

interface StoredOutcome {
  claimed_at: number
  outcome: "shown" | "suppressed"
  tab_id: string
}

interface TabCandidate {
  eligible: boolean
  tab_id: string
  visible: boolean
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
  const outcomes = new Map<string, "shown" | "suppressed">()
  const candidates = new Map<string, Map<string, TabCandidate>>()
  const failures = new Map<string, Set<string>>()
  let closed = false

  const onMessage = (event: MessageEvent) => {
    const message = coordinationMessage(event.data)
    if (!message) return

    if (message.type === "shown" || message.type === "suppressed") {
      rememberBoundedMap(outcomes, message.event_id, message.type)
      candidates.delete(message.event_id)
      failures.delete(message.event_id)
      return
    }

    if (message.type === "failed") {
      rememberFailure(failures, message.event_id, message.tab_id)
      return
    }

    if (outcomes.has(message.event_id)) return
    rememberCandidate(candidates, message.event_id, {
      eligible: Boolean(message.eligible),
      tab_id: message.tab_id,
      visible: Boolean(message.visible),
    })
  }

  channel?.addEventListener("message", onMessage)

  return {
    async coordinate(
      rawEventId: string,
      displayCandidate: NotificationDisplayCandidate
    ): Promise<boolean> {
      if (closed) return false
      const eventId = normalizedEventId(rawEventId)
      if (!eventId) {
        return Boolean(channel) && displayCandidate.eligible && !displayCandidate.visible &&
          safeDisplay(displayCandidate.display)
      }

      if (!channel) return false

      if (
        attempted.has(eventId) ||
        outcomes.has(eventId) ||
        storedOutcome(storage, storageKey, eventId)
      ) {
        return false
      }

      rememberBounded(attempted, eventId)
      rememberCandidate(candidates, eventId, {
        eligible: displayCandidate.eligible,
        tab_id: tabId,
        visible: displayCandidate.visible,
      })
      channel?.postMessage({
        type: "candidate",
        event_id: eventId,
        tab_id: tabId,
        eligible: displayCandidate.eligible,
        visible: displayCandidate.visible,
      } satisfies CoordinationMessage)

      if (channel) await delay(claimWindowMs)
      if (closed || outcomes.has(eventId)) return false

      const eventCandidates = [...(candidates.get(eventId)?.values() || [])]
      const visibleTabs = eventCandidates.filter((candidate) => candidate.visible)

      if (visibleTabs.length > 0) {
        const suppressor = visibleTabs.sort(compareCandidates)[0]

        if (suppressor.tab_id === tabId) {
          commitOutcome(
            storage,
            storageKey,
            channel,
            outcomes,
            eventId,
            tabId,
            "suppressed"
          )
        }

        return false
      }

      const eligibleTabs = eventCandidates
        .filter((candidate) => candidate.eligible)
        .sort(compareCandidates)

      for (const candidate of eligibleTabs) {
        if (closed || outcomes.has(eventId)) return false
        if (failures.get(eventId)?.has(candidate.tab_id)) continue

        if (candidate.tab_id === tabId) {
          if (safeDisplay(displayCandidate.display)) {
            return commitOutcome(
              storage,
              storageKey,
              channel,
              outcomes,
              eventId,
              tabId,
              "shown"
            )
          }

          rememberFailure(failures, eventId, tabId)
          attempted.delete(eventId)
          channel?.postMessage({
            type: "failed",
            event_id: eventId,
            tab_id: tabId,
          } satisfies CoordinationMessage)
          return false
        }

        await waitForCandidate(
          eventId,
          candidate.tab_id,
          outcomes,
          failures,
          claimWindowMs
        )
      }

      attempted.delete(eventId)
      return false
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
  {notificationState}: MentionNotificationOptions
): boolean {
  if (document.visibilityState !== "hidden") return false
  if (!mentionNotificationEligible(message, {notificationState})) return false

  const options: NotificationOptions = {
    body: `${message.nick}: ${message.body}`,
  }
  if (message.event_id) options.tag = normalizedEventId(message.event_id)

  try {
    new window.Notification(message.channel || message.peer_nick || "topics.club", options)
    return true
  } catch (_error) {
    return false
  }
}

export function mentionNotificationEligible(
  _message: MentionMessage,
  {notificationState}: MentionNotificationOptions
): boolean {
  if (window.isSecureContext === false) return false
  if (!("Notification" in window)) return false
  if (notificationState !== "granted" && window.Notification.permission !== "granted") return false
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

function storedOutcome(
  storage: NotificationClaimStorage | null,
  storageKey: string,
  eventId: string
): StoredOutcome | null {
  const outcomes = storedOutcomes(storage, storageKey)
  return outcomes[eventId] || null
}

function storeOutcome(
  storage: NotificationClaimStorage | null,
  storageKey: string,
  eventId: string,
  tabId: string,
  outcome: "shown" | "suppressed"
): boolean {
  if (!storage) return true

  try {
    const outcomes = storedOutcomes(storage, storageKey)
    if (outcomes[eventId]) return false
    outcomes[eventId] = {claimed_at: Date.now(), outcome, tab_id: tabId}

    const boundedOutcomes = Object.fromEntries(
      Object.entries(outcomes)
        .sort(([, left], [, right]) => right.claimed_at - left.claimed_at)
        .slice(0, CLAIM_LIMIT)
    )
    storage.setItem(storageKey, JSON.stringify(boundedOutcomes))
    return storedOutcomes(storage, storageKey)[eventId]?.tab_id === tabId
  } catch (_error) {
    return true
  }
}

function storedOutcomes(
  storage: NotificationClaimStorage | null,
  storageKey: string
): Record<string, StoredOutcome> {
  if (!storage) return {}

  try {
    const parsed = JSON.parse(storage.getItem(storageKey) || "{}")
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return {}
    const cutoff = Date.now() - CLAIM_TTL_MS

    return Object.fromEntries(
      Object.entries(parsed).flatMap(([eventId, value]) => {
        const stored = value as Partial<StoredOutcome> | null
        const outcome = stored?.outcome === "suppressed" ? "suppressed" : "shown"

        return Boolean(
          stored &&
          typeof stored.claimed_at === "number" &&
          stored.claimed_at >= cutoff &&
          typeof stored.tab_id === "string"
        )
          ? [[eventId, {...stored, outcome} as StoredOutcome]]
          : []
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

  if (
    !eventId ||
    !message.tab_id ||
    !["candidate", "failed", "shown", "suppressed"].includes(message.type || "")
  ) {
    return null
  }

  return {
    eligible: Boolean(message.eligible),
    event_id: eventId,
    tab_id: String(message.tab_id),
    type: message.type!,
    visible: Boolean(message.visible),
  }
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

function rememberBoundedMap<T>(values: Map<string, T>, key: string, value: T): void {
  values.set(key, value)
  if (values.size <= CLAIM_LIMIT) return
  const oldest = values.keys().next().value
  if (oldest) values.delete(oldest)
}

function rememberCandidate(
  candidates: Map<string, Map<string, TabCandidate>>,
  eventId: string,
  candidate: TabCandidate
): void {
  const eventCandidates = candidates.get(eventId) || new Map<string, TabCandidate>()
  eventCandidates.set(candidate.tab_id, candidate)
  rememberBoundedMap(candidates, eventId, eventCandidates)
}

function rememberFailure(
  failures: Map<string, Set<string>>,
  eventId: string,
  tabId: string
): void {
  const eventFailures = failures.get(eventId) || new Set<string>()
  eventFailures.add(tabId)
  rememberBoundedMap(failures, eventId, eventFailures)
}

function compareCandidates(left: TabCandidate, right: TabCandidate): number {
  return left.tab_id.localeCompare(right.tab_id)
}

function safeDisplay(display: () => boolean): boolean {
  try {
    return display()
  } catch (_error) {
    return false
  }
}

function commitOutcome(
  storage: NotificationClaimStorage | null,
  storageKey: string,
  channel: NotificationBroadcastChannel | null,
  outcomes: Map<string, "shown" | "suppressed">,
  eventId: string,
  tabId: string,
  outcome: "shown" | "suppressed"
): boolean {
  if (!storeOutcome(storage, storageKey, eventId, tabId, outcome)) return false

  rememberBoundedMap(outcomes, eventId, outcome)
  channel?.postMessage({type: outcome, event_id: eventId, tab_id: tabId} satisfies CoordinationMessage)
  return outcome === "shown"
}

async function waitForCandidate(
  eventId: string,
  tabId: string,
  outcomes: Map<string, "shown" | "suppressed">,
  failures: Map<string, Set<string>>,
  claimWindowMs: number
): Promise<void> {
  const timeoutAt = Date.now() + Math.max(25, claimWindowMs * 2)

  while (
    Date.now() < timeoutAt &&
    !outcomes.has(eventId) &&
    !failures.get(eventId)?.has(tabId)
  ) {
    await delay(1)
  }
}

function uniqueTabId(): string {
  return globalThis.crypto?.randomUUID?.() || `tab-${Date.now()}-${Math.random().toString(36).slice(2)}`
}

function delay(milliseconds: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, milliseconds))
}
