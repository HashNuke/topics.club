import type {ChatUser, PresenceDiff, PresenceDiffPayload, PresenceSyncPayload} from "./types.ts"
import {
  nonemptyString,
  record,
  validBufferId,
  validEntityId,
  validIsoTimestamp,
  validTimestampedEventId,
} from "./protocol_payload.ts"

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
      validTimestampedEventId(
        value.event_id,
        `${type === "presence:sync" ? "presence_sync" : "presence_diff"}:${value.buffer_id}`
      ) &&
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
  return validBufferId(value) && value.startsWith("channel:")
}
