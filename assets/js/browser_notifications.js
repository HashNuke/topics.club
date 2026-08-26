export function notificationPermission() {
  if (!("Notification" in window)) return "default"
  return window.Notification.permission
}

export async function requestNotificationPermission() {
  if (!("Notification" in window)) return "unsupported"
  return window.Notification.requestPermission()
}

export function showMentionNotification(message, {currentUser, notificationState}) {
  if (!("Notification" in window)) return false
  if (document.visibilityState !== "hidden") return false
  if (notificationState !== "granted" && window.Notification.permission !== "granted") return false
  if (message.nick === currentUser?.email?.split("@")[0]) return false

  new window.Notification(message.channel || "topics.club", {body: `${message.nick}: ${message.body}`})
  return true
}
