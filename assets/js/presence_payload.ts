import type {ChatUser, PresenceDiff, PresenceDiffPayload, PresenceSyncPayload} from "./types.ts"

const roles = new Set(["owner", "admin", "op", "halfop", "voice", "user"])
const statuses = new Set(["online", "away", "unknown"])

export function validPresenceSyncPayload(value: unknown): value is PresenceSyncPayload {
  if (!validPresenceEnvelope(value, "presence:sync") || !Array.isArray(value.users)) {
    return false
  }

  return validUserList(value.users)
}

export function validPresenceDiffPayload(value: unknown): value is PresenceDiffPayload {
  return validPresenceEnvelope(value, "presence:diff") && validPresenceDiff(value.diff)
}

export function validPresenceUsersByBuffer(value: unknown): value is Record<string, ChatUser[]> {
  if (!record(value)) return false

  return Object.entries(value).every(
    ([bufferId, users]) =>
      validPresenceBufferId(bufferId) && Array.isArray(users) && validUserList(users)
  )
}

export function validChatUser(value: unknown): value is ChatUser {
  return Boolean(
    record(value) &&
      nonemptyString(value.nick) &&
      nonemptyString(value.nick_key) &&
      (value.role === undefined || (typeof value.role === "string" && roles.has(value.role))) &&
      (value.status === undefined ||
        (typeof value.status === "string" && statuses.has(value.status)))
  )
}

function validPresenceDiff(value: unknown): value is PresenceDiff {
  if (!record(value)) return false

  switch (value.action) {
    case "join":
      return validChatUser(value.user)

    case "part":
    case "quit":
      return nonemptyString(value.nick) && nonemptyString(value.nick_key)

    case "nick":
      return (
        nonemptyString(value.old_nick) &&
        nonemptyString(value.old_nick_key) &&
        nonemptyString(value.new_nick) &&
        nonemptyString(value.new_nick_key)
      )

    case "away":
      return (
        nonemptyString(value.nick) &&
        nonemptyString(value.nick_key) &&
        typeof value.status === "string" &&
        statuses.has(value.status)
      )

    case "role":
      return (
        nonemptyString(value.nick) &&
        nonemptyString(value.nick_key) &&
        typeof value.role === "string" &&
        roles.has(value.role)
      )

    default:
      return false
  }
}

function validPresenceEnvelope(
  value: unknown,
  type: "presence:sync" | "presence:diff"
): value is Record<string, unknown> {
  return Boolean(
    record(value) &&
      value.type === type &&
      value.version === 1 &&
      nonemptyString(value.event_id) &&
      validIsoTimestamp(value.occurred_at) &&
      validEntityId(value.server_connection_id) &&
      validEntityId(value.channel_membership_id) &&
      value.buffer_id === `channel:${value.channel_membership_id}`
  )
}

function validUserList(users: unknown[]): users is ChatUser[] {
  if (!users.every(validChatUser)) return false
  return new Set(users.map((user) => user.nick_key)).size === users.length
}

function validPresenceBufferId(value: unknown): value is string {
  return typeof value === "string" && /^channel:[1-9][0-9]{0,18}$/.test(value)
}

function nonemptyString(value: unknown): value is string {
  return typeof value === "string" && value.length > 0
}

function validIsoTimestamp(value: unknown): value is string {
  return (
    typeof value === "string" &&
    /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?Z$/.test(value) &&
    Number.isFinite(Date.parse(value))
  )
}

function validEntityId(value: unknown): value is string | number {
  if (typeof value === "number") return Number.isSafeInteger(value) && value > 0
  return typeof value === "string" && /^[1-9][0-9]{0,18}$/.test(value)
}

function record(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value)
}
