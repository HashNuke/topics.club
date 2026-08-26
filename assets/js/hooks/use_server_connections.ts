import {
  useCallback,
  useEffect,
  useRef,
  useState,
  type Dispatch,
  type MutableRefObject,
  type SetStateAction,
} from "react"
import type {ApiClient} from "../api_client.ts"
import {normalizeChannel, normalizeTopic} from "../chat_store.ts"
import {
  channelFromBuffer,
  channelFromMembership,
  directMessageFromBuffer,
  planServerRemoval,
  removeChannel,
  updateBufferRead,
  updateConnectionDetails,
  updateServerStatus,
  upsertDirectMessage,
  upsertJoinedChannel,
} from "../connection_store.ts"
import {backendTopicFor, numericId} from "../topic_navigation.ts"
import type {RealtimeClient} from "../realtime_client.ts"
import type {
  AppView,
  BackendConnection,
  BufferReadPayload,
  BufferLeftPayload,
  Channel,
  ChannelMembership,
  ChatMessage,
  ChatUser,
  DirectMessageClosedPayload,
  DirectMessageBufferRecord,
  DirectMessageThreadPayload,
  DirectMessageTombstone,
  EntityId,
  JoinedTopicPayload,
  MessagesByBuffer,
  ServerConnection,
  ServerStatusPayload,
  Topic,
  TopicInput,
  UsersByBuffer,
} from "../types.ts"

export interface ManualServerForm {
  host: string
  channels: string
  port: string | number
  useTls: boolean
  nickname: string
  saslPassword?: string
  serverPassword?: string
}

export interface EditServerForm {
  host: string
  port: string | number
  useTls: boolean
  nickname: string
}

interface ServerConnectionsOptions {
  activeChannelIdRef: MutableRefObject<string | null>
  activeServerIdRef: MutableRefObject<string | null>
  apiClient: ApiClient
  appendSystemMessage: (body: string) => void
  canJoinTopics: boolean
  connectionsRef: MutableRefObject<ServerConnection[]>
  realtimeClientRef: MutableRefObject<RealtimeClient | null>
  reconcileServerBuffers: (serverConnectionId: EntityId) => void
  setActiveChannelId: Dispatch<SetStateAction<string | null>>
  setActiveServerId: Dispatch<SetStateAction<string | null>>
  setMessagesByChannel: Dispatch<SetStateAction<MessagesByBuffer>>
  setMessagesByServer: Dispatch<SetStateAction<MessagesByBuffer>>
  setUsersByChannel: Dispatch<SetStateAction<UsersByBuffer>>
  setView: Dispatch<SetStateAction<AppView>>
  topics: Topic[]
}

export default function useServerConnections({
  activeChannelIdRef,
  activeServerIdRef,
  apiClient,
  appendSystemMessage,
  canJoinTopics,
  connectionsRef,
  realtimeClientRef,
  reconcileServerBuffers,
  setActiveChannelId,
  setActiveServerId,
  setMessagesByChannel,
  setMessagesByServer,
  setUsersByChannel,
  setView,
  topics,
}: ServerConnectionsOptions) {
  const [connections, setConnectionsState] = useState<ServerConnection[]>([])
  const rejectedBufferIdsRef = useRef(new Set<string>())
  const joinRejectionVersionsRef = useRef(new Map<string, number>())
  const directMessageRevisionsRef = useRef(new Map<string, number>())

  const setConnections = useCallback<Dispatch<SetStateAction<ServerConnection[]>>>((update) => {
    const next = typeof update === "function" ? update(connectionsRef.current) : update
    rememberDirectMessageRevisions(next)
    connectionsRef.current = next
    setConnectionsState(next)
  }, [connectionsRef])

  useEffect(() => {
    connectionsRef.current = connections
  }, [connections, connectionsRef])

  async function joinTopic(topic: TopicInput): Promise<void> {
    const normalized = normalizeTopic(topic)
    const backendTopic = backendTopicFor(normalized, topics)
    const topicId = numericId(normalized.id) || numericId(backendTopic?.id)
    if (!canJoinTopics || !topicId) return

    const rejectionVersions = new Map(joinRejectionVersionsRef.current)

    try {
      const joined = await apiClient.joinTopic(topicId)
      applyJoinedTopic(joined, false, rejectionVersions)
    } catch (_error) {
      // Keep discovery open when the backend rejects a topic join.
    }
  }

  function applyAuthoritativeJoinedTopic(payload: JoinedTopicPayload): void {
    applyJoinedTopic(payload, true)
  }

  function applyJoinedTopic(
    payload: JoinedTopicPayload,
    authoritative = false,
    rejectionVersions = new Map(joinRejectionVersionsRef.current)
  ): boolean | undefined {
    if (!validJoinedTopicPayload(payload)) return
    const {connection, buffer, topic} = payload

    if (authoritative) {
      rejectedBufferIdsRef.current.delete(buffer.buffer_id)
    } else if (rejectedBufferIdsRef.current.has(buffer.buffer_id)) {
      const previousVersion = rejectionVersions.get(buffer.buffer_id) || 0
      const currentVersion = joinRejectionVersionsRef.current.get(buffer.buffer_id) || 0
      if (currentVersion > previousVersion) return false
      rejectedBufferIdsRef.current.delete(buffer.buffer_id)
    }

    const connectionId = `server:${connection.id}`
    const channel = channelFromBuffer(buffer, topic)

    setConnections((current) => upsertJoinedChannel(current, connection, channel))
    setMessagesByChannel((current) => ({...current, [channel.id]: current[channel.id] || []}))
    setActiveServerId(connectionId)
    setActiveChannelId(channel.id)
    setView("chat")
    return true
  }

  async function joinManualServer(form: ManualServerForm): Promise<void> {
    const host = form.host.trim()
    const channels = String(form.channels || "")
      .split(",")
      .map((channel) => normalizeChannel(channel.trim()))
      .filter(Boolean)
    if (!host || channels.length === 0) return

    try {
      const {connection} = await apiClient.createConnection({
        name: host,
        host,
        port: Number(form.port) || 6669,
        use_tls: form.useTls,
        nickname: form.nickname.trim(),
        sasl_password: form.saslPassword,
        server_password: form.serverPassword,
      })

      for (const channel of channels) {
        const rejectionVersions = new Map(joinRejectionVersionsRef.current)
        const joined = await apiClient.joinChannel(connection.id, channel)
        applyJoinedChannel(connection, joined.channel, rejectionVersions)
      }
    } catch (_error) {
      appendSystemMessage("Server join failed.")
    }
  }

  function applyJoinedChannel(
    connection: BackendConnection,
    membership: ChannelMembership,
    rejectionVersions = new Map(joinRejectionVersionsRef.current)
  ): boolean | undefined {
    if (!validBackendConnection(connection) || !validChannelMembership(membership)) return

    const connectionId = `server:${connection.id}`
    const bufferId = `channel:${membership.id}`

    if (rejectedBufferIdsRef.current.has(bufferId)) {
      const previousVersion = rejectionVersions.get(bufferId) || 0
      const currentVersion = joinRejectionVersionsRef.current.get(bufferId) || 0
      if (currentVersion > previousVersion) return false
      rejectedBufferIdsRef.current.delete(bufferId)
    }

    const channel = channelFromMembership(membership, connection.host)

    setConnections((current) =>
      upsertJoinedChannel(current, connection, channel, {updateStatus: true})
    )
    setMessagesByChannel((current) => ({...current, [channel.id]: current[channel.id] || []}))
    setActiveServerId(connectionId)
    setActiveChannelId(channel.id)
    setView("chat")
    return true
  }

  function applyServerStatus(payload: ServerStatusPayload): void {
    setConnections((current) => updateServerStatus(current, payload))
    if (payload.status === "connected") defer(() => reconcileServerBuffers(payload.server_connection_id))
  }

  function applyBufferLeft(payload: BufferLeftPayload): void {
    const bufferId = payload.buffer_id
    if (bufferId?.startsWith("server:")) {
      applyServerDeleted({server_connection_id: payload.server_connection_id})
      return
    }

    const channelId = bufferId?.startsWith("channel:") ? bufferId : null
    if (!channelId) return

    rejectedBufferIdsRef.current.add(channelId)
    joinRejectionVersionsRef.current.set(
      channelId,
      (joinRejectionVersionsRef.current.get(channelId) || 0) + 1
    )

    setConnections((current) => removeChannel(current, channelId))
    setMessagesByChannel((current) => omitKeys(current, [channelId]))
    setUsersByChannel((current) => omitKeys(current, [channelId]))

    if (activeChannelIdRef.current === channelId) {
      setActiveServerId(`server:${payload.server_connection_id}`)
      setView("server")
    }
  }

  function applyBufferRead(payload: BufferReadPayload): void {
    if (!payload?.buffer_id) return
    setConnections((current) => updateBufferRead(current, payload))
  }

  function applyDirectMessageThread(payload: DirectMessageThreadPayload): boolean {
    if (!validDirectMessageThreadPayload(payload)) return false
    if (payload.buffer.direct_message_revision !== payload.revision) return false

    if (payload.buffer.closed_at) {
      applyDirectMessageClosed({
        buffer_id: payload.buffer.buffer_id,
        server_connection_id: payload.buffer.server_connection_id,
        direct_message_thread_id: payload.buffer.direct_message_thread_id,
        revision: payload.revision,
      })
      return true
    }
    if (!acceptDirectMessageRevision(payload.buffer.buffer_id, payload.revision)) return false

    const directMessage = directMessageFromBuffer(payload.buffer)
    setConnections((current) => upsertDirectMessage(current, payload.connection, directMessage))
    setMessagesByChannel((current) => ({
      ...current,
      [directMessage.id]: current[directMessage.id] || [],
    }))
    return true
  }

  function applyDirectMessageClosed(payload: DirectMessageClosedPayload): void {
    const bufferId = payload?.buffer_id
    if (!validDirectMessageClosedPayload(payload)) return
    if (!acceptDirectMessageRevision(bufferId, payload.revision)) return

    const serverId = `server:${payload.server_connection_id}`
    const currentServer = connectionsRef.current.find((server) => server.id === serverId)
    const remaining = currentServer?.channels.filter((channel) => channel.id !== bufferId) || []

    setConnections((current) => removeChannel(current, bufferId))
    setMessagesByChannel((current) => omitKeys(current, [bufferId]))
    setUsersByChannel((current) => omitKeys(current, [bufferId]))

    if (activeChannelIdRef.current !== bufferId) return

    const nextConversation = remaining[0]
    activeChannelIdRef.current = nextConversation?.id || null
    setActiveChannelId(nextConversation?.id || null)
    setActiveServerId(serverId)
    setView(nextConversation ? "chat" : "server")
  }

  async function closeDirectMessage(channel?: Channel | null): Promise<void> {
    if (channel?.buffer_type !== "direct_message" || !realtimeClientRef.current) return

    try {
      const payload = await realtimeClientRef.current.push<DirectMessageClosedPayload>(
        "direct_message:close",
        {buffer_id: channel.id}
      )
      applyDirectMessageClosed(payload)
    } catch (_error) {
      // Keep the thread visible if the backend cannot close it.
    }
  }

  async function setDirectMessageBlocked(channel: Channel, blocked: boolean): Promise<void> {
    if (channel.buffer_type !== "direct_message" || !realtimeClientRef.current) return

    try {
      const payload = await realtimeClientRef.current.push<DirectMessageThreadPayload>(
        "direct_message:block",
        {buffer_id: channel.id, blocked}
      )
      applyDirectMessageThread(payload)
    } catch (_error) {
      // Preserve the current blocking state if the backend rejects the change.
    }
  }

  async function leaveChannel(channel?: Channel | null): Promise<void> {
    if (!channel?.id || !realtimeClientRef.current) return

    try {
      await realtimeClientRef.current.push("channel:leave", {buffer_id: channel.id})
    } catch (_error) {
      // The channel remains visible if the backend cannot leave it.
    }
  }

  async function reconnectServer(server?: ServerConnection | null): Promise<void> {
    if (!server?.server_connection_id || !realtimeClientRef.current) return

    try {
      const status = await realtimeClientRef.current.push<ServerStatusPayload>("server:reconnect", {
        server_connection_id: server.server_connection_id,
      })
      applyServerStatus(status)
    } catch (_error) {
      // Keep the current server status if reconnect fails.
    }
  }

  async function disconnectServer(server?: ServerConnection | null): Promise<void> {
    if (!server?.server_connection_id || !realtimeClientRef.current) return

    try {
      const status = await realtimeClientRef.current.push<ServerStatusPayload>("server:disconnect", {
        server_connection_id: server.server_connection_id,
      })
      applyServerStatus(status)
    } catch (_error) {
      // Keep the current server status if disconnect fails.
    }
  }

  async function leaveServer(server?: ServerConnection | null): Promise<void> {
    if (!server?.server_connection_id) return

    try {
      const {deleted} = await apiClient.deleteConnection(server.server_connection_id)
      applyServerDeleted(deleted || {server_connection_id: server.server_connection_id})
    } catch (_error) {
      // Keep the server visible if deletion fails.
    }
  }

  async function updateServerConnection(server: ServerConnection | null | undefined, form: EditServerForm): Promise<void> {
    if (!server?.server_connection_id) return

    const host = form.host.trim()
    const nickname = form.nickname.trim()
    if (!host || !nickname) return

    try {
      const {connection} = await apiClient.updateConnection(server.server_connection_id, {
        name: server.name || host,
        host,
        port: Number(form.port) || 6669,
        use_tls: form.useTls,
        nickname,
      })
      if (connection?.id) setConnections((current) => updateConnectionDetails(current, connection))
    } catch (_error) {
      // Leave the current connection details visible if the backend rejects the edit.
    }
  }

  function applyServerDeleted(payload: {server_connection_id: EntityId}): void {
    const removal = planServerRemoval(connectionsRef.current, payload.server_connection_id)
    if (!removal) return

    const {deletedChannelIds, deletedServer, nextChannel, nextConnections, nextServer} = removal
    connectionsRef.current = nextConnections
    setConnections(nextConnections)
    setMessagesByServer((current) => omitKeys(current, [deletedServer.id]))
    setMessagesByChannel((current) => omitKeys(current, deletedChannelIds))
    setUsersByChannel((current) => omitKeys(current, deletedChannelIds))

    if (
      activeServerIdRef.current === deletedServer.id ||
      (activeChannelIdRef.current !== null && deletedChannelIds.has(activeChannelIdRef.current))
    ) {
      if (nextChannel) {
        setActiveServerId(nextServer!.id)
        setActiveChannelId(nextChannel.id)
        setView("chat")
      } else if (nextServer) {
        setActiveServerId(nextServer.id)
        setView("server")
      } else {
        setView("discover")
      }
    }
  }

  function rememberDirectMessageRevisions(nextConnections: ServerConnection[]): void {
    for (const connection of nextConnections) {
      for (const channel of connection.channels) {
        if (
          channel.buffer_type === "direct_message" &&
          validRevision(channel.direct_message_revision)
        ) {
          const previous = directMessageRevisionsRef.current.get(channel.id) ?? -1
          if (channel.direct_message_revision > previous) {
            directMessageRevisionsRef.current.set(channel.id, channel.direct_message_revision)
          }
        }
      }
    }
  }

  function acceptDirectMessageRevision(bufferId: string, revision: number): boolean {
    if (!validRevision(revision)) return false

    const previous = directMessageRevisionsRef.current.get(bufferId) ?? -1
    if (revision <= previous) return false

    directMessageRevisionsRef.current.set(bufferId, revision)
    return true
  }

  function seedDirectMessageTombstones(tombstones: DirectMessageTombstone[]): void {
    for (const tombstone of tombstones) {
      if (!validDirectMessageClosedPayload(tombstone)) continue

      const previous = directMessageRevisionsRef.current.get(tombstone.buffer_id) ?? -1
      if (tombstone.revision > previous) {
        directMessageRevisionsRef.current.set(tombstone.buffer_id, tombstone.revision)
      }
    }
  }

  function validDirectMessageThreadPayload(payload: DirectMessageThreadPayload): boolean {
    if (!payload?.connection || !payload?.buffer) return false
    const {buffer, connection, revision} = payload
    if (
      buffer.buffer_type !== "direct_message" ||
      !validEntityId(buffer.direct_message_thread_id) ||
      !validEntityId(buffer.server_connection_id) ||
      !validEntityId(connection.id)
    ) return false

    const eventIdParts = typeof payload.event_id === "string"
      ? payload.event_id.split(":")
      : []
    const validClosedAt = buffer.closed_at === null || validIsoTimestamp(buffer.closed_at)

    return (
      payload.type === "direct_message:thread" &&
      payload.version === 1 &&
      eventIdParts.length === 3 &&
      eventIdParts[0] === "direct_message_thread" &&
      eventIdParts[1] === String(buffer.direct_message_thread_id) &&
      /^[1-9][0-9]{0,18}$/.test(eventIdParts[2]) &&
      validIsoTimestamp(payload.occurred_at) &&
      buffer.buffer_id === `direct:${buffer.direct_message_thread_id}` &&
      String(buffer.server_connection_id) === String(connection.id) &&
      typeof buffer.title === "string" &&
      buffer.title.trim().length > 0 &&
      typeof buffer.peer_nick === "string" &&
      buffer.peer_nick === buffer.title &&
      typeof buffer.subtitle === "string" &&
      buffer.subtitle.trim().length > 0 &&
      (buffer.account === null || typeof buffer.account === "string") &&
      (buffer.hostmask === null || typeof buffer.hostmask === "string") &&
      validClosedAt &&
      typeof buffer.unread_count === "number" &&
      Number.isSafeInteger(buffer.unread_count) &&
      buffer.unread_count >= 0 &&
      buffer.mention_count === 0 &&
      validRevision(buffer.direct_message_revision) &&
      typeof buffer.blocked === "boolean" &&
      validRevision(revision) &&
      revision === buffer.direct_message_revision &&
      validBackendConnection(connection)
    )
  }

  function validJoinedTopicPayload(payload: JoinedTopicPayload): boolean {
    if (!payload?.connection || !payload?.buffer) return false
    const {buffer, connection} = payload

    return (
      validBackendConnection(connection) &&
      buffer.buffer_type === "channel" &&
      validEntityId(buffer.channel_membership_id) &&
      validEntityId(buffer.server_connection_id) &&
      buffer.buffer_id === `channel:${buffer.channel_membership_id}` &&
      String(buffer.server_connection_id) === String(connection.id) &&
      typeof buffer.mention_notifications_enabled === "boolean" &&
      validRevision(buffer.notification_preference_revision)
    )
  }

  function validBackendConnection(connection: BackendConnection): boolean {
    return Boolean(
      connection &&
      validEntityId(connection.id) &&
      typeof connection.host === "string" &&
      connection.host.length > 0 &&
      typeof connection.mention_notifications_enabled === "boolean" &&
      validRevision(connection.notification_preference_revision)
    )
  }

  function validIsoTimestamp(value: unknown): value is string {
    return typeof value === "string" &&
      /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?Z$/.test(value) &&
      Number.isFinite(Date.parse(value))
  }

  function validChannelMembership(membership: ChannelMembership): boolean {
    return Boolean(
      membership &&
      validEntityId(membership.id) &&
      typeof membership.channel === "string" &&
      membership.channel.length > 0 &&
      typeof membership.mention_notifications_enabled === "boolean" &&
      validRevision(membership.notification_preference_revision)
    )
  }

  function validDirectMessageClosedPayload(payload: DirectMessageClosedPayload): boolean {
    return Boolean(
      payload &&
      validEntityId(payload.server_connection_id) &&
      validEntityId(payload.direct_message_thread_id) &&
      payload.buffer_id === `direct:${payload.direct_message_thread_id}` &&
      validRevision(payload.revision)
    )
  }

  function validRevision(value: unknown): value is number {
    return typeof value === "number" && Number.isSafeInteger(value) && value >= 0
  }

  function validEntityId(value: unknown): value is EntityId {
    if (typeof value === "number") return Number.isSafeInteger(value) && value > 0
    return typeof value === "string" && /^[1-9][0-9]{0,18}$/.test(value)
  }

  return {
    applyAuthoritativeJoinedTopic,
    applyBufferLeft,
    applyBufferRead,
    applyDirectMessageClosed,
    applyDirectMessageThread,
    applyJoinedChannel,
    applyServerStatus,
    connections,
    closeDirectMessage,
    disconnectServer,
    joinManualServer,
    joinRejectionVersionsRef,
    joinTopic,
    leaveChannel,
    leaveServer,
    reconnectServer,
    seedDirectMessageTombstones,
    setDirectMessageBlocked,
    setConnections,
    updateServerConnection,
  }
}

function omitKeys<T>(object: Record<string, T>, keys: Iterable<string>): Record<string, T> {
  const next = {...object}
  for (const key of keys) delete next[key]
  return next
}

function defer(callback: () => void): void {
  if (typeof queueMicrotask === "function") {
    queueMicrotask(callback)
    return
  }

  Promise.resolve().then(callback)
}
