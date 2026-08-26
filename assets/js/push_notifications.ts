import type {ApiClient} from "./api_client.ts"
import {
  notificationPermission,
  notificationUnavailableReason,
  type NotificationDeviceState,
} from "./browser_notifications.ts"
import type {NotificationControlState} from "./components/notification_bell.tsx"
import type {EntityId, PushConfig} from "./types.ts"

const INSTALLATION_KEY = "ircpipe.notification-installation"

interface NotificationInstallation {
  installation_id: string
  user_id: string
}

export async function inspectNotificationDevice(push: PushConfig): Promise<NotificationDeviceState> {
  const base = deviceBase(push)
  if (notificationUnavailableReason(base)) return {...base, loading: false}
  if (base.capability !== "granted") return {...base, loading: false}

  try {
    const registration = await navigator.serviceWorker.ready
    const subscription = await registration.pushManager.getSubscription()
    return {...base, loading: false, subscribed: Boolean(subscription)}
  } catch (_error) {
    return {...base, loading: false, error: "Could not inspect this device's push subscription."}
  }
}

export async function synchronizeNotificationDevice(
  apiClient: ApiClient,
  push: PushConfig,
  userId: EntityId
): Promise<NotificationDeviceState> {
  const base = deviceBase(push)
  const unavailable = notificationUnavailableReason(base)
  if (unavailable || base.capability !== "granted") return {...base, loading: false}

  try {
    const registration = await navigator.serviceWorker.ready
    let subscription = await registration.pushManager.getSubscription()
    if (!subscription) return {...base, loading: false, subscribed: false}

    if (!installationOwnedBy(userId)) {
      await subscription.unsubscribe()
      subscription = await subscribe(registration, push)
    }

    await persistSubscription(apiClient, userId, subscription)
    return {...base, loading: false, subscribed: true}
  } catch (_error) {
    return {
      ...base,
      loading: false,
      subscribed: false,
      error: "Notifications are enabled locally but could not be synchronized.",
    }
  }
}

export async function enableNotificationDevice(
  apiClient: ApiClient,
  push: PushConfig,
  userId: EntityId
): Promise<NotificationDeviceState> {
  const base = deviceBase(push)
  const unavailable = notificationUnavailableReason(base)
  if (unavailable) return {...base, loading: false, error: unavailable}

  const permission = base.capability === "granted"
    ? "granted"
    : await window.Notification.requestPermission()

  if (permission !== "granted") {
    return {...base, capability: permission, loading: false}
  }

  try {
    const registration = await navigator.serviceWorker.ready
    let existing = await registration.pushManager.getSubscription()

    if (existing && !installationOwnedBy(userId)) {
      await existing.unsubscribe()
      existing = null
    }

    const subscription = existing || await subscribe(registration, push)

    await persistSubscription(apiClient, userId, subscription)
    return {...base, capability: "granted", loading: false, subscribed: true}
  } catch (_error) {
    return {...base, capability: "granted", loading: false, error: "This device could not finish notification setup."}
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
  subscription: PushSubscription
): Promise<void> {
  const json = subscription.toJSON()
  await apiClient.savePushSubscription(notificationInstallation(userId).installation_id, {
    endpoint: json.endpoint,
    expirationTime: json.expirationTime,
    keys: json.keys,
  })
}

function installationOwnedBy(userId: EntityId): boolean {
  return storedNotificationInstallation()?.user_id === String(userId)
}

function notificationInstallation(userId: EntityId): NotificationInstallation {
  const normalizedUserId = String(userId)
  const existing = storedNotificationInstallation()
  if (existing?.user_id === normalizedUserId) return existing

  const installation = {
    installation_id: newInstallationId(),
    user_id: normalizedUserId,
  }

  try {
    localStorage.setItem(INSTALLATION_KEY, JSON.stringify(installation))
  } catch (_error) {
    // The in-memory installation still identifies this registration request.
  }

  return installation
}

function storedNotificationInstallation(): NotificationInstallation | null {
  try {
    const value = localStorage.getItem(INSTALLATION_KEY)
    if (!value) return null
    const parsed = JSON.parse(value)

    if (
      parsed &&
      typeof parsed.installation_id === "string" &&
      typeof parsed.user_id === "string"
    ) return parsed
  } catch (_error) {
    return null
  }

  return null
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
