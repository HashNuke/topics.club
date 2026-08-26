import {normalizeMessage, normalizeTopic} from "./chat_store.ts"
import {channelFromBuffer, directMessageFromBuffer, sortConversationBuffers} from "./connection_store.ts"
import type {
  AppView,
  BackendConnection,
  BufferRecord,
  ChatMessage,
  ChatUser,
  CommandCatalogEntry,
  DirectMessageTombstone,
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
  notification_state?: NotificationPermission | null
  push?: PushConfig
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
  notificationState: NotificationPermission | null
  push: PushConfig
  topics: Topic[] | null
  usersByChannel: Record<string, ChatUser[]>
  view: AppView | null
}

export function buildBootstrapState(bootstrap?: BootstrapPayload | null): BootstrapState | null {
  if (
    !bootstrap?.buffers ||
    !bootstrap?.connections ||
    !Array.isArray(bootstrap.direct_message_tombstones)
  ) return null

  const buffers = bootstrap.buffers
  const connections = bootstrap.connections.map((connection) => {
    const conversationBuffers = buffers.filter(
      (buffer) =>
        ["channel", "direct_message"].includes(buffer.buffer_type || "") &&
        buffer.server_connection_id === connection.id
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
      mention_notifications_enabled: connection.mention_notifications_enabled ?? true,
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
    activeChannelId = bootstrap.active_buffer_id
    activeServerId = connections.find((connection) =>
      connection.channels.some((channel) => channel.id === activeChannelId)
    )?.id || null
    view = "chat"
  } else if (bootstrap.active_buffer_id?.startsWith("server:")) {
    activeServerId = bootstrap.active_buffer_id
    view = "server"
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
    notificationState: bootstrap.notification_state || null,
    push: bootstrap.push || {configured: false, vapid_public_key: null},
    topics: bootstrap.topics?.length ? bootstrap.topics.map(normalizeTopic) : null,
    usersByChannel: bootstrap.users_by_buffer || {},
    view,
  }
}
