import type {
  BackendConnection,
  BufferJoinedPayload,
  BufferLeftPayload,
  BufferReadPayload,
  BufferRecord,
  ChannelBufferRecord,
  ChannelMembership,
  ChatMessage,
  CommandCatalogEntry,
  DirectMessageBufferRecord,
  DirectMessageClosedPayload,
  DirectMessageThreadPayload,
  DirectMessageTombstone,
  EntityId,
  JoinedTopicPayload,
  NotificationPreferencePayload,
  NotificationPreferenceEventPayload,
  ServerDeletedPayload,
  ServerChannel,
  ServerStatus,
  ServerStatusPayload,
  TopicInput,
} from "./types.ts"

const postgresBigintMax = "9223372036854775807"
const serverStatuses = new Set<ServerStatus>([
  "disconnected",
  "connecting",
  "connected",
  "errored",
])

const messageKinds = new Set([
  "message",
  "action",
  "notice",
  "system",
  "error",
  "command",
  "join",
  "part",
  "quit",
  "nick",
  "topic",
  "mode",
  "kick",
])
const systemMessageKinds = new Set([
  "system",
  "command",
  "join",
  "part",
  "quit",
  "nick",
  "topic",
  "mode",
  "kick",
])

export function validChatMessage(value: unknown): value is ChatMessage {
  if (!record(value)) return false

  if (
    value.version !== 1 ||
    !validEntityId(value.id) ||
    value.event_id !== `message:${value.id}` ||
    !validBufferId(value.buffer_id) ||
    !validEntityId(value.server_connection_id) ||
    !nullableEntityId(value.channel_membership_id) ||
    !nullableEntityId(value.direct_message_thread_id) ||
    !(value.nick === null || typeof value.nick === "string") ||
    !nullableString(value.hostmask) ||
    !nullableString(value.sender_role) ||
    !nullableString(value.service) ||
    !record(value.metadata) ||
    typeof value.body !== "string" ||
    typeof value.kind !== "string" ||
    !messageKinds.has(value.kind) ||
    typeof value.mentioned !== "boolean" ||
    !validOptionalUnreadCounters(value) ||
    !validIsoTimestamp(value.occurred_at) ||
    (value.peer_nick !== undefined && !nonemptyString(value.peer_nick)) ||
    (value.channel !== undefined && !nonemptyString(value.channel)) ||
    (value.blocked !== undefined && typeof value.blocked !== "boolean")
  ) return false

  const expectedType = value.kind === "error"
    ? "buffer:error"
    : systemMessageKinds.has(value.kind)
      ? "buffer:system"
      : "buffer:message"
  if (value.type !== expectedType) return false
  if (expectedType === "buffer:message" && !nonemptyString(value.nick)) return false

  return validOwningBuffer(
    value.buffer_id,
    value.server_connection_id,
    value.channel_membership_id,
    value.direct_message_thread_id
  )
}

export function canonicalChatMessage(value: unknown): ChatMessage | null {
  if (!validChatMessage(value)) return null

  return {
    type: value.type,
    version: value.version,
    id: value.id,
    event_id: value.event_id,
    buffer_id: value.buffer_id,
    server_connection_id: value.server_connection_id,
    channel_membership_id: value.channel_membership_id,
    direct_message_thread_id: value.direct_message_thread_id,
    ...(value.peer_nick === undefined ? {} : {peer_nick: value.peer_nick}),
    occurred_at: value.occurred_at,
    nick: value.nick,
    hostmask: value.hostmask,
    sender_role: value.sender_role,
    service: value.service,
    body: value.body,
    ...(value.channel === undefined ? {} : {channel: value.channel}),
    kind: value.kind,
    mentioned: value.mentioned,
    ...(value.unread_count === undefined ? {} : {unread_count: value.unread_count}),
    ...(value.mention_count === undefined ? {} : {mention_count: value.mention_count}),
    metadata: {...value.metadata},
    ...(value.blocked === undefined ? {} : {blocked: value.blocked}),
  }
}

function validOptionalUnreadCounters(value: Record<string, unknown>): boolean {
  if (value.unread_count === undefined && value.mention_count === undefined) return true

  return validUnreadCounters(value)
}

function validUnreadCounters(value: Record<string, unknown>): boolean {
  return validUnreadCounter(value.unread_count) && validUnreadCounter(value.mention_count)
}

function validUnreadCounter(value: unknown): value is number {
  return Number.isSafeInteger(value) && Number(value) >= 0
}

export function validMessagesByBuffer(
  value: unknown,
  allowedBufferIds?: ReadonlySet<string>
): value is Record<string, ChatMessage[]> {
  if (!record(value)) return false

  return Object.entries(value).every(([bufferId, messages]) =>
    validBufferId(bufferId) &&
    (!allowedBufferIds || allowedBufferIds.has(bufferId)) &&
    Array.isArray(messages) &&
    messages.every((message) => validChatMessage(message) && message.buffer_id === bufferId)
  )
}

export function validBufferReadPayload(value: unknown): value is BufferReadPayload {
  return Boolean(
    versionedEnvelope(value, "buffer:read") &&
      validTimestampedEventId(value.event_id, `buffer_read:${value.buffer_id}`) &&
      validBufferReadOrLeftOwner(value) &&
      validUnreadCounters(value)
  )
}

export function validBufferLeftPayload(value: unknown): value is BufferLeftPayload {
  if (!versionedEnvelope(value, "buffer:left") || !validBufferReadOrLeftOwner(value)) {
    return false
  }

  return validTimestampedEventId(value.event_id, `buffer_left:${value.buffer_id}`) ||
    value.event_id === `connection_deletion:${value.server_connection_id}:${value.buffer_id}`
}

export function validBufferJoinedPayload(value: unknown): value is BufferJoinedPayload {
  return Boolean(
    versionedEnvelope(value, "buffer:joined") &&
      validJoinedTopicPayload(value) &&
      validTimestampedEventId(value.event_id, `buffer_joined:${value.buffer.buffer_id}`)
  )
}

export function validJoinedTopicPayload(value: unknown): value is JoinedTopicPayload {
  if (!record(value) || !validBackendConnection(value.connection)) return false
  if (!validChannelBufferRecord(value.buffer)) return false

  return String(value.connection.id) === String(value.buffer.server_connection_id) &&
    (value.topic === undefined || validTopicInput(value.topic))
}

export function validDirectMessageThreadPayload(
  value: unknown
): value is DirectMessageThreadPayload {
  if (!versionedEnvelope(value, "direct_message:thread")) return false
  if (!validBackendConnection(value.connection) || !validDirectMessageBufferRecord(value.buffer)) {
    return false
  }

  return validRevision(value.revision) &&
    value.revision === value.buffer.direct_message_revision &&
    String(value.connection.id) === String(value.buffer.server_connection_id) &&
    validTimestampedEventId(
      value.event_id,
      `direct_message_thread:${value.buffer.direct_message_thread_id}`
    )
}

export function validDirectMessageClosedPayload(
  value: unknown
): value is DirectMessageClosedPayload {
  return Boolean(
    versionedEnvelope(value, "direct_message:closed") &&
      validDirectMessageTombstone(value) &&
      validTimestampedEventId(
        value.event_id,
        `direct_message_closed:${value.direct_message_thread_id}`
      )
  )
}

export function validServerStatusPayload(value: unknown): value is ServerStatusPayload {
  return Boolean(
    versionedEnvelope(value, "server:status") &&
      validEntityId(value.server_connection_id) &&
      validTimestampedEventId(value.event_id, `server_status:${value.server_connection_id}`) &&
      validServerStatus(value.status) &&
      nullableString(value.nickname)
  )
}

export function validServerDeletedPayload(value: unknown): value is ServerDeletedPayload {
  return Boolean(
    versionedEnvelope(value, "server:deleted") &&
      validEntityId(value.server_connection_id) &&
      validTimestampedEventId(value.event_id, `server_deleted:${value.server_connection_id}`)
  )
}

export function validNotificationPreferencePayload(
  value: unknown
): value is NotificationPreferencePayload {
  return Boolean(
    record(value) &&
      (value.scope === "server" || value.scope === "channel") &&
      validEntityId(value.id) &&
      typeof value.mention_notifications_enabled === "boolean" &&
      validRevision(value.revision)
  )
}

interface ExpectedNotificationPreferenceResponse {
  scope: "server" | "channel"
  id: EntityId
  mention_notifications_enabled: boolean
  baseRevision: number
}

export function validNotificationPreferenceResponse(
  value: unknown,
  expected: ExpectedNotificationPreferenceResponse
): value is NotificationPreferencePayload {
  return validNotificationPreferencePayload(value) &&
    value.scope === expected.scope &&
    String(value.id) === String(expected.id) &&
    value.mention_notifications_enabled === expected.mention_notifications_enabled &&
    value.revision > expected.baseRevision
}

export function validNotificationPreferenceEventPayload(
  value: unknown
): value is NotificationPreferenceEventPayload {
  return Boolean(
    versionedEnvelope(value, "notification:preference") &&
      validNotificationPreferencePayload(value) &&
      value.event_id ===
        `notification_preference:${value.scope}:${value.id}:${value.revision}`
  )
}

export function validBackendConnection(value: unknown): value is BackendConnection {
  return Boolean(
    record(value) &&
      validEntityId(value.id) &&
      nonemptyString(value.host) &&
      typeof value.mention_notifications_enabled === "boolean" &&
      validRevision(value.notification_preference_revision) &&
      (value.name === undefined || typeof value.name === "string") &&
      (value.port === undefined || (Number.isSafeInteger(value.port) && Number(value.port) > 0)) &&
      (value.use_tls === undefined || typeof value.use_tls === "boolean") &&
      (value.nickname === undefined || nullableString(value.nickname)) &&
      (value.status === undefined || validServerStatus(value.status))
  )
}

export function validChannelMembership(value: unknown): value is ChannelMembership {
  return Boolean(
    record(value) &&
      validEntityId(value.id) &&
      nonemptyString(value.channel) &&
      typeof value.mention_notifications_enabled === "boolean" &&
      validRevision(value.notification_preference_revision)
  )
}

export function validBufferRecord(value: unknown): value is BufferRecord {
  if (
    !record(value) ||
    !validBufferId(value.buffer_id) ||
    !validEntityId(value.server_connection_id) ||
    !nonemptyString(value.title) ||
    (value.status !== undefined && !validServerStatus(value.status)) ||
    !optionalNonnegativeInteger(value.unread_count) ||
    !optionalNonnegativeInteger(value.mention_count)
  ) return false

  switch (value.buffer_type) {
    case "server":
      return value.buffer_id === `server:${value.server_connection_id}` &&
        (value.channel_membership_id === null || value.channel_membership_id === undefined) &&
        (value.direct_message_thread_id === null || value.direct_message_thread_id === undefined) &&
        value.direct_message_revision === undefined &&
        validNotificationPreferenceRecord(value)

    case "channel":
      return validChannelBufferRecord(value)

    case "direct_message":
      return validDirectMessageBufferRecord(value)

    default:
      return false
  }
}

export function validChannelBufferRecord(value: unknown): value is ChannelBufferRecord {
  return Boolean(
    record(value) &&
      value.buffer_type === "channel" &&
      validEntityId(value.server_connection_id) &&
      validEntityId(value.channel_membership_id) &&
      value.buffer_id === `channel:${value.channel_membership_id}` &&
      (value.direct_message_thread_id === null || value.direct_message_thread_id === undefined) &&
      value.direct_message_revision === undefined &&
      nonemptyString(value.title) &&
      (value.subtitle === undefined || typeof value.subtitle === "string") &&
      (value.status === undefined || validServerStatus(value.status)) &&
      optionalNonnegativeInteger(value.unread_count) &&
      optionalNonnegativeInteger(value.mention_count) &&
      validNotificationPreferenceRecord(value)
  )
}

export function validDirectMessageBufferRecord(
  value: unknown
): value is DirectMessageBufferRecord {
  return Boolean(
      record(value) &&
      value.buffer_type === "direct_message" &&
      validEntityId(value.server_connection_id) &&
      (value.channel_membership_id === null || value.channel_membership_id === undefined) &&
      validEntityId(value.direct_message_thread_id) &&
      value.buffer_id === `direct:${value.direct_message_thread_id}` &&
      validRevision(value.direct_message_revision) &&
      value.mention_notifications_enabled === undefined &&
      value.notification_preference_revision === undefined &&
      nonemptyString(value.title) &&
      nonemptyString(value.subtitle) &&
      (value.status === undefined || validServerStatus(value.status)) &&
      value.peer_nick === value.title &&
      (value.account === null || typeof value.account === "string") &&
      (value.hostmask === null || typeof value.hostmask === "string") &&
      (value.closed_at === null || validIsoTimestamp(value.closed_at)) &&
      Number.isSafeInteger(value.unread_count) &&
      Number(value.unread_count) >= 0 &&
      value.mention_count === 0 &&
      typeof value.blocked === "boolean"
  )
}

export function validDirectMessageTombstone(
  value: unknown
): value is DirectMessageTombstone {
  return Boolean(
    record(value) &&
      validEntityId(value.server_connection_id) &&
      validEntityId(value.direct_message_thread_id) &&
      value.buffer_id === `direct:${value.direct_message_thread_id}` &&
      validRevision(value.revision)
  )
}

export function validBufferId(value: unknown): value is string {
  if (typeof value !== "string") return false
  const match = /^(server|channel|direct):([1-9][0-9]{0,18})$/.exec(value)
  return Boolean(match && validDecimalEntityId(match[2]))
}

export function validIsoTimestamp(value: unknown): value is string {
  return typeof value === "string" &&
    /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?Z$/.test(value) &&
    Number.isFinite(Date.parse(value))
}

export function validRevision(value: unknown): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0
}

export function validTopicInput(value: unknown): value is TopicInput {
  return Boolean(
    record(value) &&
      validEntityId(value.id) &&
      nonemptyString(value.channel) &&
      nonemptyString(value.name) &&
      nonemptyString(value.server_host) &&
      nonemptyString(value.description) &&
      Number.isSafeInteger(value.server_port) &&
      Number(value.server_port) > 0 &&
      Number(value.server_port) <= 65_535 &&
      typeof value.use_tls === "boolean"
  )
}

export function validServerChannel(value: unknown): value is ServerChannel {
  return Boolean(
    record(value) &&
      validEntityId(value.id) &&
      nonemptyString(value.name) &&
      (value.topic === undefined || value.topic === null || typeof value.topic === "string") &&
      Number.isSafeInteger(value.user_count) &&
      Number(value.user_count) >= 0 &&
      validEntityId(value.network_id) &&
      nonemptyString(value.network_name) &&
      nonemptyString(value.server_host) &&
      Number.isSafeInteger(value.server_port) &&
      Number(value.server_port) > 0 &&
      Number(value.server_port) <= 65_535 &&
      typeof value.use_tls === "boolean" &&
      (value.refreshed_at === undefined || value.refreshed_at === null || validIsoTimestamp(value.refreshed_at))
  )
}

export function validCommandCatalog(value: unknown): value is CommandCatalogEntry[] {
  return Array.isArray(value) && value.every(validCommandCatalogEntry)
}

function validCommandCatalogEntry(value: unknown): value is CommandCatalogEntry {
  return Boolean(
    record(value) &&
      nonemptyString(value.name) &&
      value.name.startsWith("/") &&
      nonemptyString(value.usage) &&
      value.usage.startsWith("/") &&
      nonemptyString(value.description) &&
      (value.required_permission === "user" || value.required_permission === "channel_operator") &&
      Array.isArray(value.contexts) &&
      value.contexts.length > 0 &&
      value.contexts.every(
        (context) => context === "server" || context === "channel" || context === "direct"
      ) &&
      (value.availability === "enabled" || value.availability === "managed_only") &&
      Array.isArray(value.examples) &&
      value.examples.length > 0 &&
      value.examples.every((example) => nonemptyString(example) && example.startsWith("/"))
  )
}

export function validEntityId(value: unknown): value is EntityId {
  if (typeof value === "number") return Number.isSafeInteger(value) && value > 0
  return typeof value === "string" && validDecimalEntityId(value)
}

export function validServerStatus(value: unknown): value is ServerStatus {
  return typeof value === "string" && serverStatuses.has(value as ServerStatus)
}

export function nonemptyString(value: unknown): value is string {
  return typeof value === "string" && value.length > 0
}

export function record(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value)
}

function versionedEnvelope(value: unknown, type: string): value is Record<string, unknown> {
  return Boolean(
    record(value) &&
      value.type === type &&
      value.version === 1 &&
      nonemptyString(value.event_id) &&
      validIsoTimestamp(value.occurred_at)
  )
}

function validBufferReadOrLeftOwner(value: Record<string, unknown>): boolean {
  return validEntityId(value.server_connection_id) &&
    nullableEntityId(value.channel_membership_id) &&
    (value.direct_message_thread_id === undefined || value.direct_message_thread_id === null) &&
    validOwningBuffer(
      value.buffer_id,
      value.server_connection_id,
      value.channel_membership_id,
      null
    )
}

function validOwningBuffer(
  bufferId: unknown,
  serverConnectionId: unknown,
  channelMembershipId: unknown,
  directMessageThreadId: unknown
): boolean {
  if (!validBufferId(bufferId) || !validEntityId(serverConnectionId)) return false

  if (bufferId === `server:${serverConnectionId}`) {
    return channelMembershipId === null && directMessageThreadId === null
  }
  if (validEntityId(channelMembershipId) && bufferId === `channel:${channelMembershipId}`) {
    return directMessageThreadId === null
  }
  return validEntityId(directMessageThreadId) && bufferId === `direct:${directMessageThreadId}` &&
    channelMembershipId === null
}

export function validTimestampedEventId(value: unknown, prefix: string): boolean {
  if (typeof value !== "string" || !value.startsWith(`${prefix}:`)) return false
  return /^[1-9][0-9]*$/.test(value.slice(prefix.length + 1))
}

function validNotificationPreferenceRecord(value: Record<string, unknown>): boolean {
  return typeof value.mention_notifications_enabled === "boolean" &&
    validRevision(value.notification_preference_revision)
}

function nullableEntityId(value: unknown): boolean {
  return value === null || validEntityId(value)
}

function nullableString(value: unknown): boolean {
  return value === null || typeof value === "string"
}

function optionalNonnegativeInteger(value: unknown): boolean {
  return value === undefined || (Number.isSafeInteger(value) && Number(value) >= 0)
}

function validDecimalEntityId(value: string): boolean {
  if (!/^[1-9][0-9]{0,18}$/.test(value)) return false
  return value.length < postgresBigintMax.length ||
    (value.length === postgresBigintMax.length && value <= postgresBigintMax)
}
