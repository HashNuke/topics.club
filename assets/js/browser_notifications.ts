export type BrowserNotificationState = NotificationPermission | "unsupported" | "insecure"

export interface NotificationDeviceState {
  capability: BrowserNotificationState
  configured: boolean
  error?: string | null
  loading: boolean
  subscribed: boolean
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
