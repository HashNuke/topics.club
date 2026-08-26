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
import type {
  AppView,
  ChatMessage,
  EntityId,
  MessagesByBuffer,
  ServerConnection,
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

  useEffect(() => {
    messagesByChannelRef.current = messagesByChannel
  }, [messagesByChannel])

  useEffect(() => {
    messagesByServerRef.current = messagesByServer
  }, [messagesByServer])

  function appendSystemMessage(body: string): void {
    const message: ChatMessage = {
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
        readingBuffersRef.current.has(channelId)
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
      const {messages = []} = await apiClient.bufferMessages(bufferId, {before: oldest.id, limit: 50})
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
    const normalized = normalizeMessage(message)
    const bufferId = normalized.buffer_id || (
      normalized.channel_membership_id ? `channel:${normalized.channel_membership_id}` : null
    )
    if (!bufferId) return

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
        readingBuffersRef.current.has(bufferId)
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

  function replacePendingMessage(channelId: string, clientMessageId: string, message: ChatMessage): void {
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

  function reconcileAllBuffers(): void {
    connectionsRef.current.forEach((server) => {
      [server.id, ...server.channels.map((channel) => channel.id)].forEach(reconcileBufferMessages)
    })
  }

  function reconcileBufferMessages(bufferId: string): void {
    if (!isBackendBufferId(bufferId) || reconcilingBuffersRef.current.has(bufferId)) return

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

    Promise.all([
      apiClient.bufferMessages(bufferId, {limit: 50}),
      ...commandIdChunks.map((ids) => apiClient.bufferMessages(bufferId, {commandIds: ids})),
    ])
      .then(([tail, ...commandUpdates]) => {
        const repairedCommands = commandUpdates.flatMap((response) => response.messages || [])
        const normalized = [...(tail.messages || []), ...repairedCommands].map(normalizeMessage)
        if (normalized.length === 0) return

        if (bufferId.startsWith("server:")) {
          setMessagesByServer((current) => ({
            ...current,
            [bufferId]: mergeNewerMessages(current[bufferId] || [], normalized),
          }))
        } else {
          setMessagesByChannel((current) => ({
            ...current,
            [bufferId]: mergeNewerMessages(current[bufferId] || [], normalized),
          }))
        }
      })
      .catch(() => {})
      .finally(() => reconcilingBuffersRef.current.delete(bufferId))
  }

  return {
    appendSystemMessage,
    applyRealtimeMessage,
    loadOlderMessages,
    markPendingFailed,
    messagesByChannel,
    messagesByServer,
    reconcileAllBuffers,
    reconcileBootstrapCursors,
    reconcileServerBuffers,
    replacePendingMessage,
    setMessagesByChannel,
    setMessagesByServer,
    updateBufferReadingState,
  }
}

function isBackendBufferId(bufferId?: string | null): bufferId is string {
  return Boolean(bufferId?.startsWith("channel:") || bufferId?.startsWith("server:"))
}

function defer(callback: () => void): void {
  if (typeof queueMicrotask === "function") {
    queueMicrotask(callback)
    return
  }

  Promise.resolve().then(callback)
}
