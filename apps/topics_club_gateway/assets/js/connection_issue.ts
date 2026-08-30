import type {TimelineMessage} from "./types.ts"

export type ConnectionEditFocus = "connection" | "credentials" | "nickname"

export interface ConnectionIssue {
  code: string
  title: string
  summary: string
  edit_focus: ConnectionEditFocus
  attempted_nickname?: string
  host?: string
  port?: number
  irc_code?: string
  technical_details?: string
}

export function latestConnectionIssue(messages: TimelineMessage[]): ConnectionIssue | null {
  for (let index = messages.length - 1; index >= 0; index -= 1) {
    const issue = messages[index]?.metadata?.connection_issue
    if (validConnectionIssue(issue)) return issue
  }

  return null
}

export function fallbackConnectionIssue(): ConnectionIssue {
  return {
    code: "connection_failed",
    title: "This connection needs attention",
    summary: "Review the connection details or try reconnecting.",
    edit_focus: "connection",
  }
}

export function connectionIssueGuidance(issue: ConnectionIssue): string {
  if (issue.edit_focus === "nickname") {
    return "Use a random nickname and reconnect now, or edit the connection to choose one yourself."
  }

  return issue.summary
}

export function randomIrcNickname(): string {
  const alphabet = "abcdefghijklmnopqrstuvwxyz0123456789"
  const bytes = new Uint8Array(6)
  globalThis.crypto.getRandomValues(bytes)
  const suffix = Array.from(bytes, (value) => alphabet[value % alphabet.length]).join("")

  return `guest_${suffix}`
}

function validConnectionIssue(value: unknown): value is ConnectionIssue {
  if (!value || typeof value !== "object") return false
  const issue = value as Record<string, unknown>

  return Boolean(
    typeof issue.code === "string" &&
      typeof issue.title === "string" &&
      typeof issue.summary === "string" &&
      ["connection", "credentials", "nickname"].includes(String(issue.edit_focus))
  )
}
