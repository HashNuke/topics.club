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
  buffer_id?: string
  channel_membership_id?: EntityId
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

export interface Channel {
  id: string
  channel_membership_id?: EntityId
  channel: string
  topic?: string
  unread_count?: number
  mention_count?: number
  connection?: ServerConnection
  [key: string]: unknown
}

export interface ServerConnection {
  id: string
  server_connection_id?: EntityId
  name?: string
  host: string
  port?: number
  use_tls?: boolean
  nickname?: string
  status?: string
  unread_count?: number
  mention_count?: number
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
  [key: string]: unknown
}

export interface BufferRecord {
  buffer_id: string
  buffer_type?: string
  server_connection_id: EntityId
  channel_membership_id?: EntityId
  title: string
  subtitle?: string
  unread_count?: number
  mention_count?: number
  status?: string
  [key: string]: unknown
}

export interface ChannelMembership {
  id: EntityId
  channel: string
  unread_count?: number
  mention_count?: number
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
  buffer: BufferRecord
  topic?: TopicInput
}

export interface BufferLeftPayload {
  buffer_id?: string
  server_connection_id: EntityId
}

export interface PresenceSyncPayload {
  buffer_id: string
  users?: ChatUser[]
}

export interface PresenceDiffPayload {
  buffer_id: string
  diff?: PresenceDiff
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

export interface DiscoverChannel {
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
