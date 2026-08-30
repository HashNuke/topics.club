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
import {isStaleDirectMessageError} from "../app_feedback.ts"
import {normalizeChannel, normalizeTopic} from "../chat_store.ts"
import {
  bufferServerConnectionId,
  channelFromBuffer,
  channelFromMembership,
  directMessageFromBuffer,
  planServerRemoval,
  removeChannel,
  updateBufferRead,
  updateChannelUnread,
  updateConnectionDetails,
  updateServerStatus,
  upsertDirectMessage,
  upsertJoinedChannel,
} from "../connection_store.ts"
import {backendTopicFor, numericId} from "../topic_navigation.ts"
import {
  validBackendConnection,
  validBufferJoinedPayload,
  validBufferLeftPayload,
  validBufferReadPayload,
  validChannelMembership,
  validChatMessage,
  validDirectMessageClosedPayload,
  validDirectMessageThreadPayload,
  validDirectMessageTombstone,
  validJoinedTopicPayload,
  validRevision,
  validServerDeletedPayload,
  validServerStatusPayload,
} from "../protocol_payload.ts"
import type {RealtimeClient} from "../realtime_client.ts"
import type {
  AppView,
  BackendConnection,
  BufferJoinedPayload,
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
import {documentVisible} from "./use_document_visibility.ts"

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
  saslPassword?: string
  serverPassword?: string
}

interface ServerConnectionsOptions {
  activeChannelIdRef: MutableRefObject<string | null>
  activeServerIdRef: MutableRefObject<string | null>
  apiClient: ApiClient
  appendSystemMessage: (body: string) => void
  canJoinTopics: boolean
  cancelDirectMessageHistory: (bufferId: string) => void
  connectionsRef: MutableRefObject<ServerConnection[]>
  realtimeClientRef: MutableRefObject<RealtimeClient | null>
  reconcileServerBuffers: (serverConnectionId: EntityId) => void
  refreshAuthoritativeBootstrap: () => void
  hydrateDirectMessageHistory: (bufferId: string) => Promise<void>
  setActiveChannelId: Dispatch<SetStateAction<string | null>>
  setActiveServerId: Dispatch<SetStateAction<string | null>>
  setMessagesByChannel: Dispatch<SetStateAction<MessagesByBuffer>>
  setMessagesByServer: Dispatch<SetStateAction<MessagesByBuffer>>
  setUsersByChannel: Dispatch<SetStateAction<UsersByBuffer>>
  setView: Dispatch<SetStateAction<AppView>>
  topics: Topic[]
  viewRef: MutableRefObject<AppView>
}

export default function useServerConnections({
  activeChannelIdRef,
  activeServerIdRef,
  apiClient,
  appendSystemMessage,
  canJoinTopics,
  cancelDirectMessageHistory,
  connectionsRef,
  hydrateDirectMessageHistory,
  realtimeClientRef,
  reconcileServerBuffers,
  refreshAuthoritativeBootstrap,
  setActiveChannelId,
  setActiveServerId,
  setMessagesByChannel,
  setMessagesByServer,
  setUsersByChannel,
  setView,
  topics,
  viewRef,
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

  function applyAuthoritativeJoinedTopic(payload: BufferJoinedPayload): void {
    if (!validBufferJoinedPayload(payload)) return
    applyJoinedTopic(payload, true)
  }

  function applyJoinedTopicResponse(payload: JoinedTopicPayload): void {
    applyJoinedTopic(payload)
  }

  function applyJoinedTopic(
    payload: JoinedTopicPayload,
    authoritative = false,
    rejectionVersions = new Map(joinRejectionVersionsRef.current)
  ): boolean | undefined {
    if (!validJoinedTopicPayload(payload)) return
    const {connection, buffer, topic} = payload
    const knownOwnerId = bufferServerConnectionId(connectionsRef.current, buffer.buffer_id)
    if (knownOwnerId !== null && String(knownOwnerId) !== String(connection.id)) return false

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
    const knownOwnerId = bufferServerConnectionId(connectionsRef.current, bufferId)
    if (knownOwnerId !== null && String(knownOwnerId) !== String(connection.id)) return false

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
    if (!validServerStatusPayload(payload)) return
    setConnections((current) => updateServerStatus(current, payload))
    if (payload.status === "connected") defer(() => reconcileServerBuffers(payload.server_connection_id))
  }

  function applyBufferLeft(payload: BufferLeftPayload): void {
    if (!validBufferLeftPayload(payload)) return
    const bufferId = payload.buffer_id
    const knownOwnerId = bufferServerConnectionId(connectionsRef.current, bufferId)
    if (
      knownOwnerId !== null &&
      String(knownOwnerId) !== String(payload.server_connection_id)
    ) return
    if (bufferId?.startsWith("server:")) {
      removeServer(payload.server_connection_id)
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
    if (!validBufferReadPayload(payload)) return
    const ownerId = bufferServerConnectionId(connectionsRef.current, payload.buffer_id)
    if (ownerId === null || String(ownerId) !== String(payload.server_connection_id)) return
    setConnections((current) => updateBufferRead(current, payload))
  }

  function applyChannelUnread(message: ChatMessage): void {
    if (!validChatMessage(message) || !message.buffer_id.startsWith("channel:")) return
    if (message.unread_count === undefined || message.mention_count === undefined) return
    if (
      documentVisible() &&
      viewRef.current === "chat" &&
      activeChannelIdRef.current === message.buffer_id
    ) return

    const ownerId = bufferServerConnectionId(connectionsRef.current, message.buffer_id)
    if (ownerId === null || String(ownerId) !== String(message.server_connection_id)) return

    setConnections((current) =>
      updateChannelUnread(current, message.buffer_id, message.unread_count!, message.mention_count!)
    )
  }

  function applyDirectMessageThread(payload: DirectMessageThreadPayload): boolean {
    if (!validDirectMessageThreadPayload(payload)) return false
    if (payload.buffer.direct_message_revision !== payload.revision) return false
    const knownOwnerId = bufferServerConnectionId(
      connectionsRef.current,
      payload.buffer.buffer_id
    )
    if (
      knownOwnerId !== null &&
      String(knownOwnerId) !== String(payload.buffer.server_connection_id)
    ) return false

    if (payload.buffer.closed_at) {
      return applyDirectMessageTombstone({
        buffer_id: payload.buffer.buffer_id,
        server_connection_id: payload.buffer.server_connection_id,
        direct_message_thread_id: payload.buffer.direct_message_thread_id,
        revision: payload.revision,
      })
    }
    if (!acceptDirectMessageRevision(payload.buffer.buffer_id, payload.revision)) return false

    const directMessage = directMessageFromBuffer(payload.buffer)
    setConnections((current) => upsertDirectMessage(current, payload.connection, directMessage))
    setMessagesByChannel((current) => ({
      ...current,
      [directMessage.id]: current[directMessage.id] || [],
    }))
    defer(() => hydrateDirectMessageHistory(directMessage.id))
    return true
  }

  function applyDirectMessageClosed(payload: DirectMessageClosedPayload): void {
    if (!validDirectMessageClosedPayload(payload)) return
    const knownOwnerId = bufferServerConnectionId(connectionsRef.current, payload.buffer_id)
    if (
      knownOwnerId !== null &&
      String(knownOwnerId) !== String(payload.server_connection_id)
    ) return
    applyDirectMessageTombstone(payload)
  }

  function applyDirectMessageTombstone(payload: DirectMessageTombstone): boolean {
    const bufferId = payload.buffer_id
    if (!acceptDirectMessageRevision(bufferId, payload.revision)) return false
    cancelDirectMessageHistory(bufferId)

    const serverId = `server:${payload.server_connection_id}`
    const currentServer = connectionsRef.current.find((server) => server.id === serverId)
    const remaining = currentServer?.channels.filter((channel) => channel.id !== bufferId) || []

    setConnections((current) => removeChannel(current, bufferId))
    setMessagesByChannel((current) => omitKeys(current, [bufferId]))
    setUsersByChannel((current) => omitKeys(current, [bufferId]))

    if (activeChannelIdRef.current !== bufferId) return true

    const nextConversation = remaining[0]
    activeChannelIdRef.current = nextConversation?.id || null
    setActiveChannelId(nextConversation?.id || null)
    setActiveServerId(serverId)
    setView(nextConversation ? "chat" : "server")
    return true
  }

  async function closeDirectMessage(channel?: Channel | null): Promise<void> {
    if (channel?.buffer_type !== "direct_message" || !realtimeClientRef.current) return

    try {
      const payload = await realtimeClientRef.current.push<DirectMessageClosedPayload>(
        "direct_message:close",
        {
          buffer_id: channel.id,
          expected_revision: channel.direct_message_revision,
        }
      )
      applyDirectMessageClosed(payload)
    } catch (error: unknown) {
      if (isStaleDirectMessageError(error)) refreshAuthoritativeBootstrap()
      // Keep the thread visible if the backend cannot close it.
    }
  }

  async function setDirectMessageBlocked(channel: Channel, blocked: boolean): Promise<void> {
    if (channel.buffer_type !== "direct_message" || !realtimeClientRef.current) return

    try {
      const payload = await realtimeClientRef.current.push<DirectMessageThreadPayload>(
        "direct_message:block",
        {
          buffer_id: channel.id,
          blocked,
          expected_revision: channel.direct_message_revision,
        }
      )
      applyDirectMessageThread(payload)
    } catch (error: unknown) {
      if (isStaleDirectMessageError(error)) refreshAuthoritativeBootstrap()
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

  async function reconnectServer(server?: ServerConnection | null): Promise<boolean> {
    if (!server?.server_connection_id || !realtimeClientRef.current) return false

    try {
      if (server.status === "errored") {
        const disconnected = await realtimeClientRef.current.push<ServerStatusPayload>("server:disconnect", {
          server_connection_id: server.server_connection_id,
        })
        applyServerStatus(disconnected)
      }

      const status = await realtimeClientRef.current.push<ServerStatusPayload>("server:reconnect", {
        server_connection_id: server.server_connection_id,
      })
      applyServerStatus(status)
      return true
    } catch (_error) {
      return false
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
      if (
        !validServerDeletedPayload(deleted) ||
        String(deleted.server_connection_id) !== String(server.server_connection_id)
      ) return
      removeServer(deleted.server_connection_id)
    } catch (_error) {
      // Keep the server visible if deletion fails.
    }
  }

  async function updateServerConnection(server: ServerConnection | null | undefined, form: EditServerForm, reconnect = false): Promise<boolean> {
    if (!server?.server_connection_id) return false

    const host = form.host.trim()
    const nickname = form.nickname.trim()
    if (!host || !nickname) return false

    try {
      const credentials = {
        ...(form.saslPassword ? {sasl_password: form.saslPassword} : {}),
        ...(form.serverPassword ? {server_password: form.serverPassword} : {}),
      }
      const {connection} = await apiClient.updateConnection(server.server_connection_id, {
        name: server.name || host,
        host,
        port: Number(form.port) || 6669,
        use_tls: form.useTls,
        nickname,
        ...credentials,
      })
      if (connection?.id) setConnections((current) => updateConnectionDetails(current, connection))
      if (reconnect && !(await reconnectServer(server))) return false
      return true
    } catch (_error) {
      return false
    }
  }

  function removeServer(serverConnectionId: EntityId): void {
    const removal = planServerRemoval(connectionsRef.current, serverConnectionId)
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
      if (!validDirectMessageTombstone(tombstone)) continue

      const previous = directMessageRevisionsRef.current.get(tombstone.buffer_id) ?? -1
      if (tombstone.revision > previous) {
        directMessageRevisionsRef.current.set(tombstone.buffer_id, tombstone.revision)
      }
    }
  }

  return {
    applyAuthoritativeJoinedTopic,
    applyBufferLeft,
    applyBufferRead,
    applyChannelUnread,
    applyDirectMessageClosed,
    applyDirectMessageThread,
    applyJoinedChannel,
    applyJoinedTopicResponse,
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
