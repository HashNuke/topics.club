interface MentionMessage {
  body: string
  channel?: string
  nick: string
}

export type BrowserNotificationState = NotificationPermission | "unsupported" | "insecure"

interface MentionNotificationOptions {
  currentUser?: {email?: string} | null
  notificationState: BrowserNotificationState
}

export function notificationPermission(): BrowserNotificationState {
  if (window.isSecureContext === false) return "insecure"
  if (!("Notification" in window)) return "unsupported"
  return window.Notification.permission
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

  new window.Notification(message.channel || "topics.club", {body: `${message.nick}: ${message.body}`})
  return true
}
