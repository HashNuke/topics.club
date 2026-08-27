export type EntityId = string | number
export type AppView = "chat" | "server" | "discover" | "directory"
export type ConnectionHealth = "connected" | "disconnected" | "reconnecting" | "degraded"
export type ServerStatus = "disconnected" | "connecting" | "connected" | "errored"

export interface CurrentUser {
  id: EntityId
  email: string
  message_retention_days?: number
}

export interface CommandMetadata {
  command_id?: string
  command_status?: "sent" | "acknowledged" | "completed" | "failed" | "timed_out"
  [key: string]: unknown
}

export type MessageEventType = "buffer:message" | "buffer:error" | "buffer:system"

export interface ChatMessage {
  type: MessageEventType
  version: 1
  id: EntityId
  event_id: string
  buffer_id: string
  server_connection_id: EntityId
  channel_membership_id: EntityId | null
  direct_message_thread_id: EntityId | null
  peer_nick?: string
  occurred_at: string
  nick: string | null
  hostmask: string | null
  sender_role: string | null
  service: string | null
  body: string
  channel?: string
  kind: string
  mentioned: boolean
  unread_count?: number
  mention_count?: number
  metadata: CommandMetadata
  blocked?: boolean
  [key: string]: unknown
}

export interface TimelineMessage extends Partial<ChatMessage> {
  nick: string | null
  body: string
  occurredAt?: string
  clientMessageId?: string
  pending?: boolean
  failed?: boolean
  [key: string]: unknown
}

export interface ChatUser {
  nick: string
  nick_key: string
  role?: string
  status?: string
  [key: string]: unknown
}

export type PresenceDiff =
  | {action: "join"; user: ChatUser}
  | {action: "part" | "quit"; nick: string; nick_key: string}
  | {
      action: "nick"
      old_nick: string
      old_nick_key: string
      new_nick: string
      new_nick_key: string
    }
  | {action: "away"; nick: string; nick_key: string; status: string}
  | {action: "role"; nick: string; nick_key: string; role: string}

export interface TopicInput {
  id: EntityId
  channel: string
  name: string
  server_host: string
  server_port: number
  description: string
  use_tls: boolean
}

export interface Topic extends TopicInput {
  members?: number
  member_count?: number
  vibe?: string
  [key: string]: unknown
}

interface ConversationBase {
  id: string
  channel: string
  topic?: string
  unread_count?: number
  mention_count?: number
  connection?: ServerConnection
  [key: string]: unknown
}

export interface JoinedChannel extends ConversationBase {
  buffer_type: "channel"
  channel_membership_id: EntityId
  direct_message_thread_id?: never
  mention_notifications_enabled: boolean
  notification_preference_revision: number
  direct_message_revision?: never
}

export interface DirectMessageChannel extends ConversationBase {
  buffer_type: "direct_message"
  channel_membership_id?: never
  direct_message_thread_id: EntityId
  mention_notifications_enabled?: never
  notification_preference_revision?: never
  direct_message_revision: number
  account?: string | null
  hostmask?: string | null
  blocked: boolean
  closed_at?: string | null
}

export type Channel = JoinedChannel | DirectMessageChannel

export interface ServerConnection {
  id: string
  server_connection_id: EntityId
  name?: string
  host: string
  port?: number
  use_tls?: boolean
  nickname?: string
  status?: ServerStatus
  unread_count?: number
  mention_count?: number
  mention_notifications_enabled: boolean
  notification_preference_revision: number
  channels: Channel[]
  [key: string]: unknown
}

export interface BackendConnection {
  id: EntityId
  name?: string
  host: string
  port?: number
  use_tls?: boolean
  nickname?: string
  status?: ServerStatus
  unread_count?: number
  mention_count?: number
  mention_notifications_enabled: boolean
  notification_preference_revision: number
  [key: string]: unknown
}

interface BufferRecordBase {
  buffer_id: string
  server_connection_id: EntityId
  title: string
  subtitle?: string
  unread_count?: number
  mention_count?: number
  status?: ServerStatus
  [key: string]: unknown
}

export interface ServerBufferRecord extends BufferRecordBase {
  buffer_type: "server"
  channel_membership_id?: null
  direct_message_thread_id?: never
  mention_notifications_enabled: boolean
  notification_preference_revision: number
  direct_message_revision?: never
}

export interface ChannelBufferRecord extends BufferRecordBase {
  buffer_type: "channel"
  channel_membership_id: EntityId
  direct_message_thread_id?: never
  mention_notifications_enabled: boolean
  notification_preference_revision: number
  direct_message_revision?: never
}

export interface DirectMessageBufferRecord extends BufferRecordBase {
  buffer_type: "direct_message"
  channel_membership_id?: null
  direct_message_thread_id: EntityId
  mention_notifications_enabled?: never
  notification_preference_revision?: never
  direct_message_revision: number
  subtitle: string
  peer_nick: string
  account: string | null
  hostmask: string | null
  blocked: boolean
  closed_at: string | null
  unread_count: number
  mention_count: number
}

export type BufferRecord = ServerBufferRecord | ChannelBufferRecord | DirectMessageBufferRecord

export interface ChannelMembership {
  id: EntityId
  channel: string
  unread_count?: number
  mention_count?: number
  mention_notifications_enabled: boolean
  notification_preference_revision: number
  [key: string]: unknown
}

export interface BufferReadPayload {
  type: "buffer:read"
  version: 1
  event_id: string
  occurred_at: string
  buffer_id: string
  server_connection_id: EntityId
  channel_membership_id: EntityId | null
  unread_count: number
  mention_count: number
}

export interface ServerStatusPayload {
  type: "server:status"
  version: 1
  event_id: string
  occurred_at: string
  server_connection_id: EntityId
  status: ServerStatus
  nickname: string | null
}

export interface ServerDeletedPayload {
  type: "server:deleted"
  version: 1
  event_id: string
  occurred_at: string
  server_connection_id: EntityId
}

export interface JoinedTopicPayload {
  connection: BackendConnection
  buffer: ChannelBufferRecord
  topic?: TopicInput
}

export interface BufferLeftPayload {
  type: "buffer:left"
  version: 1
  event_id: string
  occurred_at: string
  buffer_id: string
  server_connection_id: EntityId
  channel_membership_id: EntityId | null
}

export interface BufferJoinedPayload extends JoinedTopicPayload {
  type: "buffer:joined"
  version: 1
  event_id: string
  occurred_at: string
}

export interface DirectMessageThreadPayload {
  type: "direct_message:thread"
  version: 1
  event_id: string
  connection: BackendConnection
  buffer: DirectMessageBufferRecord
  revision: number
  occurred_at: string
}

export interface DirectMessageClosedPayload {
  type: "direct_message:closed"
  version: 1
  event_id: string
  occurred_at: string
  buffer_id: string
  server_connection_id: EntityId
  direct_message_thread_id: EntityId
  revision: number
}

export interface DirectMessageTombstone {
  buffer_id: string
  server_connection_id: EntityId
  direct_message_thread_id: EntityId
  revision: number
}

export interface PresenceSyncPayload {
  type: "presence:sync"
  version: 1
  event_id: string
  occurred_at: string
  buffer_id: string
  server_connection_id: EntityId
  channel_membership_id: EntityId
  users: ChatUser[]
}

export interface PresenceDiffPayload {
  type: "presence:diff"
  version: 1
  event_id: string
  occurred_at: string
  buffer_id: string
  server_connection_id: EntityId
  channel_membership_id: EntityId
  diff: PresenceDiff
}

export interface PushConfig {
  configured: boolean
  vapid_public_key: string | null
  session_generation: string
  session_installation_id: string | null
  session_registration_confirmed: boolean
}

export interface NotificationPreferencePayload {
  scope: "server" | "channel"
  id: EntityId
  mention_notifications_enabled: boolean
  revision: number
}

export interface NotificationPreferenceEventPayload extends NotificationPreferencePayload {
  type: "notification:preference"
  version: 1
  event_id: string
  occurred_at: string
}

export type MessagesByBuffer = Record<string, TimelineMessage[]>
export type UsersByBuffer = Record<string, ChatUser[]>

export interface CommandCatalogEntry {
  name: string
  usage: string
  description: string
  required_permission: "user" | "channel_operator"
  contexts: Array<"server" | "channel">
  availability: "enabled" | "managed_only"
  examples: string[]
  [key: string]: unknown
}

export interface ChannelDirectoryEntry {
  channel: string
  users?: number
  topic?: string | null
}

export interface ChannelDirectory {
  server_connection_id?: EntityId
  channels: ChannelDirectoryEntry[]
}

export interface ServerChannel {
  id: EntityId
  name: string
  topic?: string | null
  user_count: number
  network_id: EntityId
  network_name: string
  server_host: string
  server_port: number
  use_tls: boolean
  refreshed_at?: string | null
}
