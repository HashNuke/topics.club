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
let latestSynchronizationEpoch = 0
let latestSynchronizationGeneration: string | null = null

interface SynchronizationContext {
  epoch: number
  sessionGeneration: string
}

class SupersededNotificationSynchronization extends Error {}

interface NotificationInstallation {
  installation_id: string
  server_registration_confirmed: boolean
  session_generation: string
  user_id: string
}

export async function synchronizeNotificationDevice(
  apiClient: ApiClient,
  push: PushConfig,
  userId: EntityId
): Promise<NotificationDeviceState> {
  const synchronization = beginSynchronization(push)
  reconcileNotificationInstallation(userId, push)
  const base = deviceBase(push)
  const unavailable = notificationUnavailableReason(base)
  if (unavailable || base.capability !== "granted") return {...base, loading: false}
  let serverRegistrationConfirmed = notificationServerRegistrationConfirmed(userId, push)

  try {
    const registration = await navigator.serviceWorker.ready
    ensureCurrentSynchronization(synchronization)
    let subscription = await registration.pushManager.getSubscription()
    ensureCurrentSynchronization(synchronization)
    if (!subscription) {
      setServerRegistrationConfirmed(userId, push, false)
      return {...base, loading: false, subscribed: false}
    }

    if (!installationOwnedBy(userId, push)) {
      try {
        await persistSubscription(apiClient, userId, push, subscription, synchronization)
        return {...base, loading: false, subscribed: true}
      } catch (error) {
        if (!subscriptionOwnedByAnotherAccount(error)) throw error
        await subscription.unsubscribe()
        ensureCurrentSynchronization(synchronization)
        subscription = await subscribe(registration, push)
        ensureCurrentSynchronization(synchronization)
        serverRegistrationConfirmed = false
      }
    }

    await persistSubscription(apiClient, userId, push, subscription, synchronization)
    return {...base, loading: false, subscribed: true}
  } catch (error) {
    if (error instanceof SupersededNotificationSynchronization) {
      return {...base, loading: false, subscribed: false}
    }

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
  const synchronization = beginSynchronization(push)
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
    ensureCurrentSynchronization(synchronization)
    let existing = await registration.pushManager.getSubscription()
    ensureCurrentSynchronization(synchronization)

    if (existing && !installationOwnedBy(userId, push)) {
      try {
        await persistSubscription(apiClient, userId, push, existing, synchronization)
        return {...base, capability: "granted", loading: false, subscribed: true}
      } catch (error) {
        if (!subscriptionOwnedByAnotherAccount(error)) throw error
        await existing.unsubscribe()
        ensureCurrentSynchronization(synchronization)
        existing = null
        serverRegistrationConfirmed = false
      }
    }

    const subscription = existing || await subscribe(registration, push)
    ensureCurrentSynchronization(synchronization)

    await persistSubscription(apiClient, userId, push, subscription, synchronization)
    return {...base, capability: "granted", loading: false, subscribed: true}
  } catch (error) {
    if (error instanceof SupersededNotificationSynchronization) {
      return {...base, capability: "granted", loading: false, subscribed: false}
    }

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
  push: PushConfig
): boolean {
  const installation = storedNotificationInstallation()
  return installation?.user_id === String(userId) &&
    installation.session_generation === push.session_generation &&
    installation.server_registration_confirmed
}

export function notificationDeliveryCoveredByPush(
  device: NotificationDeviceState,
  userId: EntityId,
  push: PushConfig
): boolean {
  return device.subscribed || notificationServerRegistrationConfirmed(userId, push)
}

export function clearNotificationServerRegistration(): void {
  latestSynchronizationEpoch += 1
  latestSynchronizationGeneration = null
  const installation = storedNotificationInstallation()
  if (installation) storeNotificationInstallation({...installation, server_registration_confirmed: false})
}

function deviceBase(push: PushConfig): NotificationDeviceState {
  const capability = pushCapability()
  return {capability, configured: push.configured, loading: true, subscribed: false}
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
  subscription: PushSubscription,
  synchronization: SynchronizationContext
): Promise<void> {
  ensureCurrentSynchronization(synchronization)
  const json = subscription.toJSON()
  const installation = notificationInstallation(userId, push)
  const response = await apiClient.savePushSubscription(installation.installation_id, {
    endpoint: json.endpoint,
    expirationTime: json.expirationTime,
    keys: json.keys,
  })
  ensureCurrentSynchronization(synchronization)
  const installationId = response.subscription.installation_id
  if (typeof installationId !== "string" || installationId.length === 0) {
    throw new Error("invalid_push_subscription_response")
  }

  storeNotificationInstallation({
    ...installation,
    installation_id: installationId,
    server_registration_confirmed: true,
    session_generation: push.session_generation,
  })
}

function beginSynchronization(push: PushConfig): SynchronizationContext {
  latestSynchronizationEpoch += 1
  latestSynchronizationGeneration = push.session_generation

  return {
    epoch: latestSynchronizationEpoch,
    sessionGeneration: latestSynchronizationGeneration,
  }
}

function ensureCurrentSynchronization(synchronization: SynchronizationContext): void {
  if (
    synchronization.epoch !== latestSynchronizationEpoch ||
    synchronization.sessionGeneration !== latestSynchronizationGeneration
  ) {
    throw new SupersededNotificationSynchronization()
  }
}

function installationOwnedBy(userId: EntityId, push: PushConfig): boolean {
  const installation = storedNotificationInstallation()
  return installation?.user_id === String(userId) &&
    installation.session_generation === push.session_generation
}

function notificationInstallation(userId: EntityId, push: PushConfig): NotificationInstallation {
  const normalizedUserId = String(userId)
  const existing = storedNotificationInstallation()
  if (
    existing?.user_id === normalizedUserId &&
    existing.session_generation === push.session_generation
  ) return existing

  const installation = {
    installation_id: newInstallationId(),
    server_registration_confirmed: false,
    session_generation: push.session_generation,
    user_id: normalizedUserId,
  }

  storeNotificationInstallation(installation)

  return installation
}

function storedNotificationInstallation(): NotificationInstallation | null {
  let value: string | null

  try {
    value = localStorage.getItem(INSTALLATION_KEY)
  } catch (_error) {
    return inMemoryInstallation
  }

  if (!value) return inMemoryInstallation

  try {
    const parsed = JSON.parse(value)

    if (
      parsed &&
      typeof parsed.installation_id === "string" && parsed.installation_id.length > 0 &&
      typeof parsed.user_id === "string" && /^[1-9][0-9]{0,18}$/.test(parsed.user_id) &&
      typeof parsed.session_generation === "string" && parsed.session_generation.length > 0 &&
      typeof parsed.server_registration_confirmed === "boolean"
    ) {
      inMemoryInstallation = {
        installation_id: parsed.installation_id,
        server_registration_confirmed: parsed.server_registration_confirmed,
        session_generation: parsed.session_generation,
        user_id: parsed.user_id,
      }
      return inMemoryInstallation
    }
  } catch (_error) {
    discardStoredNotificationInstallation()
    return null
  }

  discardStoredNotificationInstallation()
  return null
}

function discardStoredNotificationInstallation(): void {
  inMemoryInstallation = null

  try {
    localStorage.removeItem(INSTALLATION_KEY)
  } catch (_error) {
    // This runtime no longer trusts the malformed persisted record.
  }
}

function setServerRegistrationConfirmed(
  userId: EntityId,
  push: PushConfig,
  confirmed: boolean
): void {
  const installation = storedNotificationInstallation()
  if (
    installation?.user_id !== String(userId) ||
    installation.session_generation !== push.session_generation
  ) return
  storeNotificationInstallation({
    ...installation,
    server_registration_confirmed: confirmed,
  })
}

function reconcileNotificationInstallation(userId: EntityId, push: PushConfig): void {
  const normalizedUserId = String(userId)
  const existing = storedNotificationInstallation()

  if (push.session_installation_id) {
    storeNotificationInstallation({
      installation_id: push.session_installation_id,
      server_registration_confirmed: push.session_registration_confirmed,
      session_generation: push.session_generation,
      user_id: normalizedUserId,
    })
    return
  }

  if (existing?.user_id === normalizedUserId) {
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
  return globalThis.crypto.randomUUID()
}

function subscribe(registration: ServiceWorkerRegistration, push: PushConfig): Promise<PushSubscription> {
  if (!push.configured || !push.vapid_public_key) {
    return Promise.reject(new Error("push_not_configured"))
  }

  return registration.pushManager.subscribe({
    userVisibleOnly: true,
    applicationServerKey: urlBase64ToUint8Array(push.vapid_public_key),
  })
}

function urlBase64ToUint8Array(value: string): Uint8Array<ArrayBuffer> {
  const padding = "=".repeat((4 - value.length % 4) % 4)
  const base64 = (value + padding).replace(/-/g, "+").replace(/_/g, "/")
  const raw = atob(base64)
  return Uint8Array.from(raw, (character) => character.charCodeAt(0))
}
