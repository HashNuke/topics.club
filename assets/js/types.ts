export type EntityId = string | number
export type AppView = "chat" | "server" | "discover" | "directory"
export type ConnectionHealth = "connected" | "disconnected" | "reconnecting" | "degraded"

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

export interface ChatMessage {
  id?: EntityId
  event_id?: string
  buffer_id?: string
  server_connection_id?: EntityId
  channel_membership_id?: EntityId
  direct_message_thread_id?: EntityId
  peer_nick?: string
  occurredAt?: string
  occurred_at?: string
  nick: string
  body: string
  channel?: string
  kind?: string
  mentioned?: boolean
  metadata?: CommandMetadata
  clientMessageId?: string
  pending?: boolean
  failed?: boolean
  [key: string]: unknown
}

export interface NotificationEventPayload extends ChatMessage {
  buffer_id: string
  event_id: string
  notification_id: EntityId
  server_connection_id: EntityId
}

export interface ChatUser {
  nick: string
  role?: string
  status?: string
  [key: string]: unknown
}

export interface PresenceDiff {
  action?: "join" | "part" | "quit" | "nick" | "away" | "role"
  user?: ChatUser
  nick?: string
  old_nick?: string
  new_nick?: string
  status?: string
  role?: string
}

export interface Topic {
  id: EntityId
  channel: string
  name: string
  server_host: string
  server_port?: number
  description: string
  members?: number
  member_count?: number
  vibe: string
  [key: string]: unknown
}

export interface TopicInput extends Partial<Topic> {
  id?: EntityId
  channel?: string
  name?: string
  server_host: string
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
  status?: string
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
  status?: string
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
  status?: string
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
  account?: string | null
  hostmask?: string | null
  blocked: boolean
  closed_at?: string | null
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
  buffer_id: string
  unread_count?: number
  mention_count?: number
}

export interface ServerStatusPayload {
  server_connection_id: EntityId
  status: string
  nickname?: string
}

export interface JoinedTopicPayload {
  connection: BackendConnection
  buffer: ChannelBufferRecord
  topic?: TopicInput
}

export interface BufferLeftPayload {
  buffer_id?: string
  server_connection_id: EntityId
}

export interface DirectMessageThreadPayload {
  connection: BackendConnection
  buffer: DirectMessageBufferRecord
  revision: number
}

export interface DirectMessageClosedPayload {
  buffer_id: string
  server_connection_id: EntityId
  direct_message_thread_id: EntityId
  revision: number
}

export type DirectMessageTombstone = DirectMessageClosedPayload

export interface PresenceSyncPayload {
  buffer_id: string
  users?: ChatUser[]
}

export interface PresenceDiffPayload {
  buffer_id: string
  diff?: PresenceDiff
}

export interface PushConfig {
  configured: boolean
  vapid_public_key?: string | null
  session_generation?: string | null
  session_installation_id?: string | null
  session_registration_confirmed?: boolean
}

export interface NotificationPreferencePayload {
  scope: "server" | "channel"
  id: EntityId
  mention_notifications_enabled: boolean
  revision: number
}

export type MessagesByBuffer = Record<string, ChatMessage[]>
export type UsersByBuffer = Record<string, ChatUser[]>

export interface CommandCatalogEntry {
  name: string
  usage?: string
  description?: string
  contexts?: string[]
  availability?: string
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
