interface MentionMessage {
  body: string
  channel?: string
  nick: string
}

interface MentionNotificationOptions {
  currentUser?: {email?: string} | null
  notificationState: NotificationPermission | "unsupported"
}

export function notificationPermission(): NotificationPermission {
  if (!("Notification" in window)) return "default"
  return window.Notification.permission
}

export async function requestNotificationPermission(): Promise<NotificationPermission | "unsupported"> {
  if (!("Notification" in window)) return "unsupported"
  return window.Notification.requestPermission()
}

export function showMentionNotification(
  message: MentionMessage,
  {currentUser, notificationState}: MentionNotificationOptions
): boolean {
  if (!("Notification" in window)) return false
  if (document.visibilityState !== "hidden") return false
  if (notificationState !== "granted" && window.Notification.permission !== "granted") return false
  if (message.nick === currentUser?.email?.split("@")[0]) return false

  new window.Notification(message.channel || "topics.club", {body: `${message.nick}: ${message.body}`})
  return true
}
