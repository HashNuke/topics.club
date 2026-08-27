import {
  useEffect,
  useRef,
  useState,
  type MutableRefObject,
} from "react"
import type {ApiClient} from "../api_client.ts"
import {
  appendTimelineMessage,
  mergeNewerMessages,
  mergeOlderMessages,
  normalizeMessage,
  trimMessagesToLimit,
} from "../chat_store.ts"
import {bufferServerConnectionId} from "../connection_store.ts"
import {validBufferId, validChatMessage} from "../protocol_payload.ts"
import type {
  AppView,
  ChatMessage,
  EntityId,
  MessagesByBuffer,
  ServerConnection,
  TimelineMessage,
} from "../types.ts"

interface BufferMessagesOptions {
  activeChannelIdRef: MutableRefObject<string | null>
  activeServerIdRef: MutableRefObject<string | null>
  apiClient: ApiClient
  connectionsRef: MutableRefObject<ServerConnection[]>
  markBufferRead: (bufferId: string) => Promise<void>
  viewRef: MutableRefObject<AppView>
}

export default function useBufferMessages({
  activeChannelIdRef,
  activeServerIdRef,
  apiClient,
  connectionsRef,
  markBufferRead,
  viewRef,
}: BufferMessagesOptions) {
  const [messagesByChannel, setMessagesByChannel] = useState<MessagesByBuffer>({})
  const [messagesByServer, setMessagesByServer] = useState<MessagesByBuffer>({})
  const loadingOlderRef = useRef(new Set<string>())
  const readingBuffersRef = useRef(new Set<string>())
  const messagesByChannelRef = useRef(messagesByChannel)
  const messagesByServerRef = useRef(messagesByServer)
  const reconcilingBuffersRef = useRef(new Set<string>())
  const directHydrationGenerationsRef = useRef(new Map<string, number>())
  const directHydrationsInFlightRef = useRef(new Set<string>())
  const directHydrationRetriesRef = useRef(new Set<string>())
  const hydratedDirectMessagesRef = useRef(new Set<string>())

  useEffect(() => {
    messagesByChannelRef.current = messagesByChannel
  }, [messagesByChannel])

  useEffect(() => {
    messagesByServerRef.current = messagesByServer
  }, [messagesByServer])

  function appendSystemMessage(body: string): void {
    const message: TimelineMessage = {
      id: `system-${Date.now()}`,
      occurredAt: new Date().toISOString(),
      nick: "topics.club",
      body,
      kind: "system",
    }
    const serverId = viewRef.current === "server" ? activeServerIdRef.current : null

    if (serverId) {
      setMessagesByServer((current) => ({
        ...current,
        [serverId]: appendTimelineMessage(
          current[serverId] || [],
          message,
          readingBuffersRef.current.has(serverId)
        ),
      }))
      return
    }

    const channelId = activeChannelIdRef.current
    if (!channelId) return

    setMessagesByChannel((current) => ({
      ...current,
      [channelId]: appendTimelineMessage(
        current[channelId] || [],
        message,
        readingBuffersRef.current.has(channelId),
        channelId.startsWith("direct:") ? Number.POSITIVE_INFINITY : undefined
      ),
    }))
  }

  async function loadOlderMessages(bufferId?: string | null): Promise<void> {
    if (!bufferId || loadingOlderRef.current.has(bufferId) || !isBackendBufferId(bufferId)) return

    const currentMessages = bufferId.startsWith("server:")
      ? messagesByServerRef.current[bufferId] || []
      : messagesByChannelRef.current[bufferId] || []
    const oldest = currentMessages[0]
    if (!oldest?.id || String(oldest.id).startsWith("client-")) return

    loadingOlderRef.current.add(bufferId)

    try {
      const response = await apiClient.bufferMessages(bufferId, {before: oldest.id, limit: 50})
      const messages = canonicalMessages(response.messages, bufferId)
      if (!messages) return
      const normalized = messages.map(normalizeMessage)
      if (normalized.length === 0) return

      if (bufferId.startsWith("server:")) {
        setMessagesByServer((current) => ({
          ...current,
          [bufferId]: mergeOlderMessages(normalized, current[bufferId] || []),
        }))
      } else {
        setMessagesByChannel((current) => ({
          ...current,
          [bufferId]: mergeOlderMessages(normalized, current[bufferId] || []),
        }))
      }
    } catch (_error) {
      // Keep the current scrollback stable if history pagination fails.
    } finally {
      loadingOlderRef.current.delete(bufferId)
    }
  }

  function applyRealtimeMessage(message: ChatMessage): void {
    if (!validChatMessage(message)) return
    const bufferId = message.buffer_id
    const ownerId = bufferServerConnectionId(connectionsRef.current, bufferId)
    if (ownerId === null || String(ownerId) !== String(message.server_connection_id)) return
    const normalized = normalizeMessage(message)

    if (bufferId.startsWith("server:")) {
      setMessagesByServer((current) => ({
        ...current,
        [bufferId]: appendTimelineMessage(
          current[bufferId] || [],
          normalized,
          readingBuffersRef.current.has(bufferId)
        ),
      }))
      return
    }

    setMessagesByChannel((current) => ({
      ...current,
      [bufferId]: appendTimelineMessage(
        current[bufferId] || [],
        normalized,
        readingBuffersRef.current.has(bufferId) || bufferId.startsWith("direct:")
      ),
    }))

    if (viewRef.current === "chat" && activeChannelIdRef.current === bufferId) {
      defer(() => markBufferRead(bufferId))
    }
  }

  function updateBufferReadingState(bufferId: string | null | undefined, readingOlder: boolean): void {
    if (!bufferId) return

    if (readingOlder) {
      readingBuffersRef.current.add(bufferId)
      return
    }

    if (!readingBuffersRef.current.has(bufferId)) return

    readingBuffersRef.current.delete(bufferId)
    pruneBufferMessages(bufferId)
  }

  function pruneBufferMessages(bufferId: string): void {
    if (bufferId.startsWith("direct:")) return

    if (bufferId.startsWith("server:")) {
      setMessagesByServer((current) => ({
        ...current,
        [bufferId]: trimMessagesToLimit(current[bufferId] || []),
      }))
      return
    }

    setMessagesByChannel((current) => ({
      ...current,
      [bufferId]: trimMessagesToLimit(current[bufferId] || []),
    }))
  }

  function replacePendingMessage(channelId: string, clientMessageId: string, message: TimelineMessage): void {
    setMessagesByChannel((current) => ({
      ...current,
      [channelId]: (current[channelId] || []).map((currentMessage) =>
        currentMessage.clientMessageId === clientMessageId ? message : currentMessage
      ),
    }))
  }

  function markPendingFailed(channelId: string, clientMessageId: string): void {
    setMessagesByChannel((current) => ({
      ...current,
      [channelId]: (current[channelId] || []).map((currentMessage) =>
        currentMessage.clientMessageId === clientMessageId
          ? {...currentMessage, pending: false, failed: true}
          : currentMessage
      ),
    }))
  }

  function reconcileBootstrapCursors(cursorsByBuffer: Record<string, unknown>): void {
    Object.keys(cursorsByBuffer).forEach(reconcileBufferMessages)
  }

  function reconcileServerBuffers(serverConnectionId: EntityId): void {
    const server = connectionsRef.current.find(
      (connection) => connection.server_connection_id === serverConnectionId
    )
    if (!server) return

    [server.id, ...server.channels.map((channel) => channel.id)].forEach(reconcileBufferMessages)
  }

  function reconcileAllBuffers(): Promise<void> {
    return Promise.all(
      connectionsRef.current.flatMap((server) =>
        [server.id, ...server.channels.map((channel) => channel.id)].map(reconcileBufferMessages)
      )
    ).then(() => undefined)
  }

  function reconcileBufferMessages(bufferId: string): Promise<void> {
    if (!isBackendBufferId(bufferId) || reconcilingBuffersRef.current.has(bufferId)) {
      return Promise.resolve()
    }

    reconcilingBuffersRef.current.add(bufferId)

    const currentMessages = bufferId.startsWith("server:")
      ? messagesByServerRef.current[bufferId] || []
      : messagesByChannelRef.current[bufferId] || []
    const commandIds = [...new Set(
      currentMessages
        .filter((message) => {
          const status = message.metadata?.command_status
          return message.kind === "command" && (status === "sent" || status === "acknowledged")
        })
        .map((message) => message.metadata?.command_id)
        .filter((commandId): commandId is string => Boolean(commandId))
    )]
    const commandIdChunks = []
    for (let index = 0; index < commandIds.length; index += 50) {
      commandIdChunks.push(commandIds.slice(index, index + 50))
    }

    return Promise.all([
      apiClient.bufferMessages(bufferId, {limit: 50}),
      ...commandIdChunks.map((ids) => apiClient.bufferMessages(bufferId, {commandIds: ids})),
    ])
      .then(([tail, ...commandUpdates]) => {
        const batches = [tail, ...commandUpdates].map((response) =>
          canonicalMessages(response.messages, bufferId)
        )
        if (batches.some((messages) => messages === null)) return

        const normalized = batches.flatMap((messages) => messages || []).map(normalizeMessage)
        if (normalized.length === 0) return

        if (bufferId.startsWith("server:")) {
          setMessagesByServer((current) => ({
            ...current,
            [bufferId]: mergeNewerMessages(current[bufferId] || [], normalized),
          }))
        } else {
          setMessagesByChannel((current) => ({
            ...current,
            [bufferId]: mergeNewerMessages(
              current[bufferId] || [],
              normalized,
              bufferId.startsWith("direct:") ? Number.POSITIVE_INFINITY : undefined
            ),
          }))
        }
      })
      .catch(() => {})
      .finally(() => reconcilingBuffersRef.current.delete(bufferId))
  }

  async function hydrateDirectMessageHistory(bufferId: string): Promise<void> {
    if (!directMessageExists(connectionsRef.current, bufferId)) return
    if (hydratedDirectMessagesRef.current.has(bufferId)) return
    if (directHydrationsInFlightRef.current.has(bufferId)) {
      directHydrationRetriesRef.current.add(bufferId)
      return
    }

    const generation = directHydrationGenerationsRef.current.get(bufferId) || 0
    directHydrationsInFlightRef.current.add(bufferId)

    try {
      let messages: TimelineMessage[] | null = null

      for (let attempt = 0; attempt < 2 && messages === null; attempt += 1) {
        const attemptMessages: TimelineMessage[] = []
        const seenMessageIds = new Set<string>()
        let before: ChatMessage | undefined
        let restart = false

        while (directHydrationCurrent(bufferId, generation)) {
          const params = before === undefined ? {limit: 150} : {limit: 150, before: before.id}
          const response = await apiClient.bufferMessages(bufferId, params)
          const page = canonicalMessages(response.messages, bufferId)
          if (!page) return

          if (!pageContinuesHistory(page, before, seenMessageIds)) {
            restart = true
            break
          }

          attemptMessages.unshift(...page.map(normalizeMessage))
          if (page.length < 150) {
            messages = attemptMessages
            break
          }

          before = page[0]
        }

        if (!directHydrationCurrent(bufferId, generation)) return
        if (restart && attempt === 1) return
      }

      if (!messages || !directHydrationCurrent(bufferId, generation)) return

      setMessagesByChannel((current) => ({
        ...current,
        [bufferId]: mergeOlderMessages(messages, current[bufferId] || []),
      }))
      hydratedDirectMessagesRef.current.add(bufferId)
    } catch (_error) {
      // Keep newly received messages visible if retained history cannot be loaded.
    } finally {
      if ((directHydrationGenerationsRef.current.get(bufferId) || 0) === generation) {
        directHydrationsInFlightRef.current.delete(bufferId)

        if (directHydrationRetriesRef.current.delete(bufferId)) {
          defer(() => hydrateDirectMessageHistory(bufferId))
        }
      }
    }
  }

  function cancelDirectMessageHistory(bufferId: string): void {
    const generation = directHydrationGenerationsRef.current.get(bufferId) || 0
    directHydrationGenerationsRef.current.set(bufferId, generation + 1)
    directHydrationsInFlightRef.current.delete(bufferId)
    directHydrationRetriesRef.current.delete(bufferId)
    hydratedDirectMessagesRef.current.delete(bufferId)
  }

  function reconcileDirectMessageHistories(
    previousConnections: ServerConnection[],
    nextConnections: ServerConnection[]
  ): void {
    const previousIds = directMessageIds(previousConnections)
    const nextIds = directMessageIds(nextConnections)

    previousIds.forEach((bufferId) => {
      if (!nextIds.has(bufferId)) cancelDirectMessageHistory(bufferId)
    })

    nextIds.forEach((bufferId) => {
      cancelDirectMessageHistory(bufferId)
      defer(() => hydrateDirectMessageHistory(bufferId))
    })
  }

  function directHydrationCurrent(bufferId: string, generation: number): boolean {
    return (directHydrationGenerationsRef.current.get(bufferId) || 0) === generation &&
      directMessageExists(connectionsRef.current, bufferId)
  }

  function replaceBootstrapMessages(
    channels: MessagesByBuffer,
    servers: MessagesByBuffer
  ): void {
    messagesByChannelRef.current = channels
    messagesByServerRef.current = servers
    setMessagesByChannel(channels)
    setMessagesByServer(servers)
  }

  return {
    appendSystemMessage,
    applyRealtimeMessage,
    cancelDirectMessageHistory,
    hydrateDirectMessageHistory,
    loadOlderMessages,
    markPendingFailed,
    messagesByChannel,
    messagesByServer,
    reconcileAllBuffers,
    reconcileDirectMessageHistories,
    reconcileBootstrapCursors,
    reconcileServerBuffers,
    replaceBootstrapMessages,
    replacePendingMessage,
    setMessagesByChannel,
    setMessagesByServer,
    updateBufferReadingState,
  }
}

function directMessageExists(connections: ServerConnection[], bufferId: string): boolean {
  return connections.some((connection) => connection.channels.some((channel) =>
    channel.id === bufferId &&
    channel.buffer_type === "direct_message"
  ))
}

function directMessageIds(connections: ServerConnection[]): Set<string> {
  return new Set(connections.flatMap((connection) =>
    connection.channels
      .filter((channel) => channel.buffer_type === "direct_message")
      .map((channel) => channel.id)
  ))
}

function pageContinuesHistory(
  page: ChatMessage[],
  before: ChatMessage | undefined,
  seenMessageIds: Set<string>
): boolean {
  for (let index = 0; index < page.length; index += 1) {
    const message = page[index]
    const key = String(message.id)
    if (seenMessageIds.has(key)) return false
    if (before !== undefined && compareMessageOrder(message, before) >= 0) return false
    if (index > 0 && compareMessageOrder(message, page[index - 1]) <= 0) return false
    seenMessageIds.add(key)
  }

  return true
}

function compareMessageOrder(left: ChatMessage, right: ChatMessage): number {
  const occurredAtComparison = timestampMicroseconds(left.occurred_at) - timestampMicroseconds(right.occurred_at)
  if (occurredAtComparison < 0n) return -1
  if (occurredAtComparison > 0n) return 1

  const idComparison = BigInt(String(left.id)) - BigInt(String(right.id))
  if (idComparison < 0n) return -1
  if (idComparison > 0n) return 1
  return 0
}

function timestampMicroseconds(timestamp: string): bigint {
  const withoutZulu = timestamp.slice(0, -1)
  const [wholeSeconds, fraction = ""] = withoutZulu.split(".")
  const milliseconds = BigInt(Date.parse(`${wholeSeconds}Z`))
  const fractionalMicroseconds = BigInt((fraction || "0").padEnd(6, "0"))
  return milliseconds * 1_000n + fractionalMicroseconds
}

function isBackendBufferId(bufferId?: string | null): bufferId is string {
  return validBufferId(bufferId)
}

function canonicalMessages(messages: unknown, bufferId: string): ChatMessage[] | null {
  if (!Array.isArray(messages)) return null
  return messages.every((message) => validChatMessage(message) && message.buffer_id === bufferId)
    ? messages
    : null
}

function defer(callback: () => void): void {
  if (typeof queueMicrotask === "function") {
    queueMicrotask(callback)
    return
  }

  Promise.resolve().then(callback)
}
