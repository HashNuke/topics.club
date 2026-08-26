import type {ApiClient} from "./api_client.ts"
import {
  notificationPermission,
  notificationUnavailableReason,
  type NotificationDeviceState,
} from "./browser_notifications.ts"
import type {NotificationControlState} from "./components/notification_bell.tsx"
import type {EntityId, PushConfig} from "./types.ts"

const INSTALLATION_KEY = "ircpipe.notification-installation"
let inMemoryInstallation: NotificationInstallation | null = null

interface NotificationInstallation {
  installation_id: string
  server_registration_confirmed: boolean
  session_generation: string | null
  user_id: string
}

export async function synchronizeNotificationDevice(
  apiClient: ApiClient,
  push: PushConfig,
  userId: EntityId
): Promise<NotificationDeviceState> {
  reconcileNotificationInstallation(userId, push)
  const base = deviceBase(push)
  const unavailable = notificationUnavailableReason(base)
  if (unavailable || base.capability !== "granted") return {...base, loading: false}
  let serverRegistrationConfirmed = notificationServerRegistrationConfirmed(userId, push)

  try {
    const registration = await navigator.serviceWorker.ready
    let subscription = await registration.pushManager.getSubscription()
    if (!subscription) {
      setServerRegistrationConfirmed(userId, push, false)
      return {...base, loading: false, subscribed: false}
    }

    if (!installationOwnedBy(userId, push)) {
      try {
        await persistSubscription(apiClient, userId, push, subscription)
        return {...base, loading: false, subscribed: true}
      } catch (error) {
        if (!subscriptionOwnedByAnotherAccount(error)) throw error
        await subscription.unsubscribe()
        subscription = await subscribe(registration, push)
        serverRegistrationConfirmed = false
      }
    }

    await persistSubscription(apiClient, userId, push, subscription)
    return {...base, loading: false, subscribed: true}
  } catch (_error) {
    return {
      ...base,
      loading: false,
      subscribed: serverRegistrationConfirmed,
      error: "Notifications are enabled locally but could not be synchronized.",
    }
  }
}

export async function enableNotificationDevice(
  apiClient: ApiClient,
  push: PushConfig,
  userId: EntityId
): Promise<NotificationDeviceState> {
  reconcileNotificationInstallation(userId, push)
  const base = deviceBase(push)
  const unavailable = notificationUnavailableReason(base)
  if (unavailable) return {...base, loading: false, error: unavailable}
  let serverRegistrationConfirmed = notificationServerRegistrationConfirmed(userId, push)

  const permission = base.capability === "granted"
    ? "granted"
    : await window.Notification.requestPermission()

  if (permission !== "granted") {
    return {...base, capability: permission, loading: false}
  }

  try {
    const registration = await navigator.serviceWorker.ready
    let existing = await registration.pushManager.getSubscription()

    if (existing && !installationOwnedBy(userId, push)) {
      try {
        await persistSubscription(apiClient, userId, push, existing)
        return {...base, capability: "granted", loading: false, subscribed: true}
      } catch (error) {
        if (!subscriptionOwnedByAnotherAccount(error)) throw error
        await existing.unsubscribe()
        existing = null
        serverRegistrationConfirmed = false
      }
    }

    const subscription = existing || await subscribe(registration, push)

    await persistSubscription(apiClient, userId, push, subscription)
    return {...base, capability: "granted", loading: false, subscribed: true}
  } catch (_error) {
    return {
      ...base,
      capability: "granted",
      loading: false,
      subscribed: serverRegistrationConfirmed,
      error: "This device could not finish notification setup.",
    }
  }
}

export function notificationControlState(
  device: NotificationDeviceState,
  scopeEnabled = true,
  parentEnabled = true,
  parentLabel?: string
): NotificationControlState {
  const unavailable = notificationUnavailableReason(device)
  if (unavailable) return {kind: "unavailable", reason: unavailable}
  if (!device.subscribed) return {kind: "available", reason: device.error || undefined}
  if (!parentEnabled) return {kind: "disabled", reason: `Mentions are muted because ${parentLabel || "this server"} notifications are off.`}
  if (!scopeEnabled) return {kind: "disabled"}
  if (device.error) return {kind: "enabled", reason: device.error}
  return {kind: "enabled"}
}

export function notificationServerRegistrationConfirmed(
  userId: EntityId,
  push?: PushConfig
): boolean {
  const installation = storedNotificationInstallation()
  const currentSession = !push?.session_generation ||
    installation?.session_generation === push.session_generation
  return installation?.user_id === String(userId) && currentSession && installation.server_registration_confirmed
}

export function notificationDeliveryCoveredByPush(
  device: NotificationDeviceState,
  userId: EntityId,
  push?: PushConfig
): boolean {
  return device.subscribed || notificationServerRegistrationConfirmed(userId, push)
}

export function clearNotificationServerRegistration(): void {
  const installation = storedNotificationInstallation()
  if (installation) storeNotificationInstallation({...installation, server_registration_confirmed: false})
}

function deviceBase(push: PushConfig): NotificationDeviceState {
  const capability = pushCapability()
  return {capability, configured: Boolean(push.configured && push.vapid_public_key), loading: true, subscribed: false}
}

function pushCapability() {
  const permission = notificationPermission()
  if (permission === "insecure" || permission === "unsupported" || permission === "denied") return permission
  if (!("serviceWorker" in navigator) || !("PushManager" in window)) return "unsupported" as const
  return permission
}

async function persistSubscription(
  apiClient: ApiClient,
  userId: EntityId,
  push: PushConfig,
  subscription: PushSubscription
): Promise<void> {
  const json = subscription.toJSON()
  const installation = notificationInstallation(userId)
  const response = await apiClient.savePushSubscription(installation.installation_id, {
    endpoint: json.endpoint,
    expirationTime: json.expirationTime,
    keys: json.keys,
  })
  storeNotificationInstallation({
    ...installation,
    installation_id: response.subscription.installation_id,
    server_registration_confirmed: true,
    session_generation: push.session_generation || null,
  })
}

function installationOwnedBy(userId: EntityId, push: PushConfig): boolean {
  const installation = storedNotificationInstallation()
  return installation?.user_id === String(userId) &&
    (!push.session_generation || installation.session_generation === push.session_generation)
}

function notificationInstallation(userId: EntityId): NotificationInstallation {
  const normalizedUserId = String(userId)
  const existing = storedNotificationInstallation()
  if (existing?.user_id === normalizedUserId) return existing

  const installation = {
    installation_id: newInstallationId(),
    server_registration_confirmed: false,
    session_generation: null,
    user_id: normalizedUserId,
  }

  storeNotificationInstallation(installation)

  return installation
}

function storedNotificationInstallation(): NotificationInstallation | null {
  try {
    const value = localStorage.getItem(INSTALLATION_KEY)
    if (!value) return inMemoryInstallation
    const parsed = JSON.parse(value)

    if (
      parsed &&
      typeof parsed.installation_id === "string" &&
      typeof parsed.user_id === "string"
    ) {
      inMemoryInstallation = {
        installation_id: parsed.installation_id,
        server_registration_confirmed: parsed.server_registration_confirmed === true,
        session_generation: typeof parsed.session_generation === "string" ? parsed.session_generation : null,
        user_id: parsed.user_id,
      }
      return inMemoryInstallation
    }
  } catch (_error) {
    return inMemoryInstallation
  }

  return inMemoryInstallation
}

function setServerRegistrationConfirmed(
  userId: EntityId,
  push: PushConfig,
  confirmed: boolean
): void {
  const installation = storedNotificationInstallation()
  if (installation?.user_id !== String(userId)) return
  storeNotificationInstallation({
    ...installation,
    server_registration_confirmed: confirmed,
    session_generation: push.session_generation || installation.session_generation,
  })
}

function reconcileNotificationInstallation(userId: EntityId, push: PushConfig): void {
  const normalizedUserId = String(userId)
  const existing = storedNotificationInstallation()

  if (push.session_installation_id) {
    storeNotificationInstallation({
      installation_id: push.session_installation_id,
      server_registration_confirmed: push.session_registration_confirmed === true,
      session_generation: push.session_generation || null,
      user_id: normalizedUserId,
    })
    return
  }

  if (
    existing?.user_id === normalizedUserId &&
    push.session_generation &&
    existing.session_generation !== push.session_generation
  ) {
    storeNotificationInstallation({
      ...existing,
      server_registration_confirmed: false,
      session_generation: push.session_generation,
    })
  }
}

function subscriptionOwnedByAnotherAccount(error: unknown): boolean {
  return error instanceof Error && error.message.includes("push_subscription_owned_by_another_account")
}

function storeNotificationInstallation(installation: NotificationInstallation): void {
  inMemoryInstallation = installation

  try {
    localStorage.setItem(INSTALLATION_KEY, JSON.stringify(installation))
  } catch (_error) {
    // A private browser context may deny durable storage; this synchronization still proceeds.
  }
}

export function resetNotificationInstallationMemoryForTest(): void {
  inMemoryInstallation = null
}

function newInstallationId(): string {
  return globalThis.crypto?.randomUUID?.() || `installation-${Date.now()}-${Math.random().toString(36).slice(2)}`
}

function subscribe(registration: ServiceWorkerRegistration, push: PushConfig): Promise<PushSubscription> {
  return registration.pushManager.subscribe({
    userVisibleOnly: true,
    applicationServerKey: urlBase64ToUint8Array(push.vapid_public_key!),
  })
}

function urlBase64ToUint8Array(value: string): Uint8Array<ArrayBuffer> {
  const padding = "=".repeat((4 - value.length % 4) % 4)
  const base64 = (value + padding).replace(/-/g, "+").replace(/_/g, "/")
  const raw = atob(base64)
  return Uint8Array.from(raw, (character) => character.charCodeAt(0))
}
