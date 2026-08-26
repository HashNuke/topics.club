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
  server_registration_confirmed: boolean
  user_id: string
}

export async function synchronizeNotificationDevice(
  apiClient: ApiClient,
  push: PushConfig,
  userId: EntityId
): Promise<NotificationDeviceState> {
  const base = deviceBase(push)
  const unavailable = notificationUnavailableReason(base)
  if (unavailable || base.capability !== "granted") return {...base, loading: false}
  let serverRegistrationConfirmed = notificationServerRegistrationConfirmed(userId)

  try {
    const registration = await navigator.serviceWorker.ready
    let subscription = await registration.pushManager.getSubscription()
    if (!subscription) {
      setServerRegistrationConfirmed(userId, false)
      return {...base, loading: false, subscribed: false}
    }

    if (!installationOwnedBy(userId)) {
      await subscription.unsubscribe()
      subscription = await subscribe(registration, push)
      serverRegistrationConfirmed = false
    }

    await persistSubscription(apiClient, userId, subscription)
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
  const base = deviceBase(push)
  const unavailable = notificationUnavailableReason(base)
  if (unavailable) return {...base, loading: false, error: unavailable}
  let serverRegistrationConfirmed = notificationServerRegistrationConfirmed(userId)

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
      serverRegistrationConfirmed = false
    }

    const subscription = existing || await subscribe(registration, push)

    await persistSubscription(apiClient, userId, subscription)
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

export function notificationServerRegistrationConfirmed(userId: EntityId): boolean {
  const installation = storedNotificationInstallation()
  return installation?.user_id === String(userId) && installation.server_registration_confirmed
}

export function notificationDeliveryCoveredByPush(
  device: NotificationDeviceState,
  userId: EntityId
): boolean {
  return device.subscribed || notificationServerRegistrationConfirmed(userId)
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
  subscription: PushSubscription
): Promise<void> {
  const json = subscription.toJSON()
  const installation = notificationInstallation(userId)
  await apiClient.savePushSubscription(installation.installation_id, {
    endpoint: json.endpoint,
    expirationTime: json.expirationTime,
    keys: json.keys,
  })
  storeNotificationInstallation({...installation, server_registration_confirmed: true})
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
    server_registration_confirmed: false,
    user_id: normalizedUserId,
  }

  storeNotificationInstallation(installation)

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
    ) {
      return {
        installation_id: parsed.installation_id,
        server_registration_confirmed: parsed.server_registration_confirmed === true,
        user_id: parsed.user_id,
      }
    }
  } catch (_error) {
    return null
  }

  return null
}

function setServerRegistrationConfirmed(userId: EntityId, confirmed: boolean): void {
  const installation = storedNotificationInstallation()
  if (installation?.user_id !== String(userId)) return
  storeNotificationInstallation({...installation, server_registration_confirmed: confirmed})
}

function storeNotificationInstallation(installation: NotificationInstallation): void {
  try {
    localStorage.setItem(INSTALLATION_KEY, JSON.stringify(installation))
  } catch (_error) {
    // A private browser context may deny durable storage; this synchronization still proceeds.
  }
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
