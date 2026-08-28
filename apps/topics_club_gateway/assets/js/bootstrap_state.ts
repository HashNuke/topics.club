import {normalizeMessage, normalizeTopic} from "./chat_store.ts"
import {channelFromBuffer, directMessageFromBuffer, sortConversationBuffers} from "./connection_store.ts"
import {validPresenceUsersByBuffer} from "./presence_payload.ts"
import {
  validBackendConnection,
  validBufferRecord,
  validCommandCatalog,
  validDirectMessageTombstone,
  validEntityId,
  validMessagesByBuffer,
  validTopicInput,
} from "./protocol_payload.ts"
import type {
  AppView,
  BackendConnection,
  BufferRecord,
  ChannelBufferRecord,
  ChatMessage,
  ChatUser,
  CommandCatalogEntry,
  CurrentUser,
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
  user: CurrentUser
  active_buffer_id?: string | null
  buffers?: BufferRecord[]
  command_catalog: CommandCatalogEntry[]
  connections?: BackendConnection[]
  direct_message_tombstones?: DirectMessageTombstone[]
  message_cursors_by_buffer: Record<string, EntityId | null>
  messages_by_buffer: Record<string, ChatMessage[]>
  push: PushConfig
  topics: TopicInput[]
  users_by_buffer: Record<string, ChatUser[]>
}

export interface BootstrapState {
  activeChannelId: string | null
  activeServerId: string | null
  commandCatalog: CommandCatalogEntry[]
  connections: ServerConnection[]
  directMessageTombstones: DirectMessageTombstone[]
  cursorsByBuffer: Record<string, EntityId | null>
  messagesByChannel: MessagesByBuffer
  messagesByServer: MessagesByBuffer
  push: PushConfig
  topics: Topic[] | null
  usersByChannel: Record<string, ChatUser[]>
  view: AppView | null
}

export function buildBootstrapState(bootstrap?: BootstrapPayload | null): BootstrapState | null {
  if (
    !validCurrentUser(bootstrap?.user) ||
    !bootstrap?.buffers ||
    !bootstrap?.connections ||
    !Array.isArray(bootstrap.direct_message_tombstones) ||
    !validCommandCatalog(bootstrap.command_catalog) ||
    !bootstrap.message_cursors_by_buffer ||
    !bootstrap.messages_by_buffer ||
    !validPushConfig(bootstrap.push) ||
    !Array.isArray(bootstrap.topics) ||
    !bootstrap.topics.every(validTopicInput) ||
    !validPresenceUsersByBuffer(bootstrap.users_by_buffer)
  ) return null

  if (
    !bootstrap.connections.every(validBackendConnection) ||
    !bootstrap.buffers.every(validBufferRecord) ||
    !bootstrap.direct_message_tombstones.every(validDirectMessageTombstone)
  ) return null

  const connectionIds = bootstrap.connections.map((connection) => String(connection.id))
  const bufferIdList = bootstrap.buffers.map((buffer) => buffer.buffer_id)
  const bufferIds = new Set(bufferIdList)

  if (
    new Set(connectionIds).size !== connectionIds.length ||
    bufferIds.size !== bufferIdList.length ||
    !validMessagesByBuffer(bootstrap.messages_by_buffer, bufferIds) ||
    !exactKeys(bootstrap.messages_by_buffer, bufferIds) ||
    !validBootstrapCursors(
      bootstrap.message_cursors_by_buffer,
      bootstrap.messages_by_buffer,
      bufferIds
    ) ||
    !validBootstrapOwnership(
      bootstrap.connections,
      bootstrap.buffers,
      bootstrap.messages_by_buffer,
      bootstrap.direct_message_tombstones
    )
  ) return null

  const channelBufferIds = new Set(
    bootstrap.buffers
      .filter((buffer) => buffer.buffer_type === "channel")
      .map((buffer) => buffer.buffer_id)
  )

  const presenceBufferIds = Object.keys(bootstrap.users_by_buffer)

  if (
    presenceBufferIds.length !== channelBufferIds.size ||
    presenceBufferIds.some((bufferId) => !channelBufferIds.has(bufferId))
  ) {
    return null
  }

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
      bootstrap.messages_by_buffer[connection.id].map(normalizeMessage),
    ])
  )
  const messagesByChannel = Object.fromEntries(
    Object.entries(bootstrap.messages_by_buffer)
      .filter(([bufferId]) => !bufferId.startsWith("server:"))
      .map(([bufferId, messages]) => [bufferId, messages.map(normalizeMessage)])
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
    commandCatalog: bootstrap.command_catalog,
    connections,
    directMessageTombstones: bootstrap.direct_message_tombstones,
    cursorsByBuffer: bootstrap.message_cursors_by_buffer,
    messagesByChannel,
    messagesByServer,
    push: bootstrap.push,
    topics: bootstrap.topics.length > 0 ? bootstrap.topics.map(normalizeTopic) : null,
    usersByChannel: bootstrap.users_by_buffer,
    view,
  }
}

function validBootstrapOwnership(
  connections: BackendConnection[],
  buffers: BufferRecord[],
  messagesByBuffer: Record<string, ChatMessage[]>,
  tombstones: DirectMessageTombstone[]
): boolean {
  const connectionIds = new Set(connections.map((connection) => String(connection.id)))
  const buffersById = new Map(buffers.map((buffer) => [buffer.buffer_id, buffer]))

  if (!connections.every((connection) => {
    const buffer = buffersById.get(`server:${connection.id}`)
    return buffer?.buffer_type === "server" &&
      String(buffer.server_connection_id) === String(connection.id)
  })) return false

  if (!buffers.every((buffer) => connectionIds.has(String(buffer.server_connection_id)))) {
    return false
  }

  if (!Object.entries(messagesByBuffer).every(([bufferId, messages]) => {
    const owner = buffersById.get(bufferId)?.server_connection_id
    return owner !== undefined && messages.every(
      (message) => String(message.server_connection_id) === String(owner)
    )
  })) return false

  const tombstoneIds = tombstones.map((tombstone) => tombstone.buffer_id)
  if (new Set(tombstoneIds).size !== tombstoneIds.length) return false

  return tombstones.every((tombstone) => {
    if (!connectionIds.has(String(tombstone.server_connection_id))) return false
    const buffer = buffersById.get(tombstone.buffer_id)
    return !buffer || String(buffer.server_connection_id) === String(tombstone.server_connection_id)
  })
}

function validBootstrapCursors(
  cursors: Record<string, EntityId | null>,
  messagesByBuffer: Record<string, ChatMessage[]>,
  bufferIds: ReadonlySet<string>
): boolean {
  if (!exactKeys(cursors, bufferIds)) return false

  return Object.entries(cursors).every(([bufferId, cursor]) => {
    if (cursor !== null && !validEntityId(cursor)) return false
    const messages = messagesByBuffer[bufferId]
    const latestId = messages.length > 0 ? messages[messages.length - 1].id : null
    return latestId === null ? cursor === null : String(cursor) === String(latestId)
  })
}

function exactKeys(value: object, expected: ReadonlySet<string>): boolean {
  const keys = Object.keys(value)
  return keys.length === expected.size && keys.every((key) => expected.has(key))
}

function validCurrentUser(user?: CurrentUser | null): user is CurrentUser {
  return Boolean(
    user &&
    validEntityId(user.id) &&
    typeof user.email === "string" &&
    user.email.length > 0
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
