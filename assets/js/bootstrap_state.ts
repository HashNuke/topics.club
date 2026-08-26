import {normalizeMessage, normalizeTopic} from "./chat_store.ts"
import {channelFromBuffer, directMessageFromBuffer, sortConversationBuffers} from "./connection_store.ts"
import type {
  AppView,
  BackendConnection,
  BufferRecord,
  ChannelBufferRecord,
  ChatMessage,
  ChatUser,
  CommandCatalogEntry,
  DirectMessageTombstone,
  DirectMessageBufferRecord,
  EntityId,
  MessagesByBuffer,
  ServerConnection,
  Topic,
  TopicInput,
  PushConfig,
} from "./types.ts"

export interface BootstrapPayload {
  active_buffer_id?: string | null
  buffers?: BufferRecord[]
  command_catalog?: CommandCatalogEntry[]
  connections?: BackendConnection[]
  direct_message_tombstones?: DirectMessageTombstone[]
  message_cursors_by_buffer?: Record<string, unknown>
  messages_by_buffer?: MessagesByBuffer
  push: PushConfig
  topics?: TopicInput[]
  users_by_buffer?: Record<string, ChatUser[]>
}

export interface BootstrapState {
  activeChannelId: string | null
  activeServerId: string | null
  commandCatalog: CommandCatalogEntry[]
  connections: ServerConnection[]
  directMessageTombstones: DirectMessageTombstone[]
  cursorsByBuffer: Record<string, unknown>
  messagesByChannel: MessagesByBuffer
  messagesByServer: MessagesByBuffer
  push: PushConfig
  topics: Topic[] | null
  usersByChannel: Record<string, ChatUser[]>
  view: AppView | null
}

export function buildBootstrapState(bootstrap?: BootstrapPayload | null): BootstrapState | null {
  if (
    !bootstrap?.buffers ||
    !bootstrap?.connections ||
    !Array.isArray(bootstrap.direct_message_tombstones) ||
    !validPushConfig(bootstrap.push)
  ) return null

  if (
    !bootstrap.connections.every(validBackendConnection) ||
    !bootstrap.buffers.every(validBufferRecord) ||
    !bootstrap.direct_message_tombstones.every(validDirectMessageTombstone)
  ) return null

  const buffers = bootstrap.buffers
  const tombstoneRevisions = new Map(
    bootstrap.direct_message_tombstones.map((tombstone) => [
      tombstone.buffer_id,
      tombstone.revision,
    ])
  )
  const connections = bootstrap.connections.map((connection) => {
    const conversationBuffers = buffers.filter(
      (buffer): buffer is ChannelBufferRecord | DirectMessageBufferRecord => {
        if (String(buffer.server_connection_id) !== String(connection.id)) return false
        if (buffer.buffer_type === "channel") return true
        if (buffer.buffer_type !== "direct_message") return false

        const tombstoneRevision = tombstoneRevisions.get(buffer.buffer_id)
        return tombstoneRevision === undefined || buffer.direct_message_revision > tombstoneRevision
      }
    )

    return {
      id: `server:${connection.id}`,
      server_connection_id: connection.id,
      name: connection.name,
      host: connection.host,
      port: connection.port,
      use_tls: connection.use_tls,
      nickname: connection.nickname,
      status: connection.status,
      unread_count: connection.unread_count || 0,
      mention_count: connection.mention_count || 0,
      mention_notifications_enabled: connection.mention_notifications_enabled,
      notification_preference_revision: connection.notification_preference_revision,
      channels: sortConversationBuffers(
        conversationBuffers.map((buffer) =>
          buffer.buffer_type === "direct_message"
            ? directMessageFromBuffer(buffer)
            : channelFromBuffer(buffer)
        )
      ),
    }
  })

  const messagesByServer = Object.fromEntries(
    connections.map((connection) => [
      connection.id,
      (bootstrap.messages_by_buffer || {})[connection.id]?.map(normalizeMessage) || [],
    ])
  )
  const messagesByChannel = Object.fromEntries(
    Object.entries(bootstrap.messages_by_buffer || {}).map(([bufferId, messages]) => [
      bufferId,
      messages.map(normalizeMessage),
    ])
  )

  let activeChannelId: string | null = null
  let activeServerId: string | null = null
  let view: AppView | null = null

  if (
    bootstrap.active_buffer_id?.startsWith("channel:") ||
    bootstrap.active_buffer_id?.startsWith("direct:")
  ) {
    const owningConnection = connections.find((connection) =>
      connection.channels.some((channel) => channel.id === bootstrap.active_buffer_id)
    )

    if (owningConnection) {
      activeChannelId = bootstrap.active_buffer_id
      activeServerId = owningConnection.id
      view = "chat"
    }
  } else if (bootstrap.active_buffer_id?.startsWith("server:")) {
    const activeConnection = connections.find(
      (connection) => connection.id === bootstrap.active_buffer_id
    )

    if (activeConnection) {
      activeServerId = activeConnection.id
      view = "server"
    }
  }

  return {
    activeChannelId,
    activeServerId,
    commandCatalog: bootstrap.command_catalog || [],
    connections,
    directMessageTombstones: bootstrap.direct_message_tombstones,
    cursorsByBuffer: bootstrap.message_cursors_by_buffer || {},
    messagesByChannel,
    messagesByServer,
    push: bootstrap.push,
    topics: bootstrap.topics?.length ? bootstrap.topics.map(normalizeTopic) : null,
    usersByChannel: bootstrap.users_by_buffer || {},
    view,
  }
}

function validBackendConnection(connection: BackendConnection): boolean {
  return Boolean(
    connection &&
    validEntityId(connection.id) &&
    typeof connection.host === "string" &&
    connection.host.length > 0 &&
    validNotificationPreference(connection)
  )
}

function validBufferRecord(buffer: BufferRecord): boolean {
  if (
    !buffer ||
    typeof buffer.buffer_id !== "string" ||
    !validEntityId(buffer.server_connection_id) ||
    typeof buffer.title !== "string"
  ) return false

  switch (buffer.buffer_type) {
    case "server":
      return (
        buffer.buffer_id === `server:${buffer.server_connection_id}` &&
        validNotificationPreference(buffer)
      )

    case "channel":
      return (
        validEntityId(buffer.channel_membership_id) &&
        buffer.buffer_id === `channel:${buffer.channel_membership_id}` &&
        validNotificationPreference(buffer)
      )

    case "direct_message":
      return (
        validEntityId(buffer.direct_message_thread_id) &&
        buffer.buffer_id === `direct:${buffer.direct_message_thread_id}` &&
        validRevision(buffer.direct_message_revision) &&
        typeof buffer.blocked === "boolean"
      )
  }
}

function validDirectMessageTombstone(tombstone: DirectMessageTombstone): boolean {
  return Boolean(
    tombstone &&
    validEntityId(tombstone.server_connection_id) &&
    validEntityId(tombstone.direct_message_thread_id) &&
    tombstone.buffer_id === `direct:${tombstone.direct_message_thread_id}` &&
    validRevision(tombstone.revision)
  )
}

function validNotificationPreference(value: {
  mention_notifications_enabled: boolean
  notification_preference_revision: number
}): boolean {
  return (
    typeof value.mention_notifications_enabled === "boolean" &&
    validRevision(value.notification_preference_revision)
  )
}

function validPushConfig(push: PushConfig): boolean {
  return Boolean(
    push &&
    typeof push.configured === "boolean" &&
    (push.vapid_public_key === null ||
      (typeof push.vapid_public_key === "string" && push.vapid_public_key.length > 0)) &&
    (push.configured ? typeof push.vapid_public_key === "string" : push.vapid_public_key === null) &&
    typeof push.session_generation === "string" &&
    push.session_generation.length > 0 &&
    (push.session_installation_id === null ||
      (typeof push.session_installation_id === "string" && push.session_installation_id.length > 0)) &&
    typeof push.session_registration_confirmed === "boolean" &&
    (push.session_registration_confirmed
      ? typeof push.session_installation_id === "string"
      : push.session_installation_id === null)
  )
}

function validRevision(value: unknown): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0
}

function validEntityId(value: unknown): value is EntityId {
  if (typeof value === "number") return Number.isSafeInteger(value) && value > 0
  return typeof value === "string" && /^[1-9][0-9]{0,18}$/.test(value)
}
