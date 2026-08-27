import type {
  BufferJoinedPayload,
  BufferLeftPayload,
  BufferReadPayload,
  ChatMessage,
  DirectMessageClosedPayload,
  DirectMessageThreadPayload,
  NotificationPreferenceEventPayload,
  PresenceDiffPayload,
  PresenceSyncPayload,
  ServerStatusPayload,
} from "./types.ts"
import {validPresenceDiffPayload, validPresenceSyncPayload} from "./presence_payload.ts"
import {
  canonicalChatMessage,
  validBufferJoinedPayload,
  validBufferLeftPayload,
  validBufferReadPayload,
  validDirectMessageClosedPayload,
  validDirectMessageThreadPayload,
  validNotificationPreferenceEventPayload,
  validServerStatusPayload,
} from "./protocol_payload.ts"

export type RealtimePayload = Record<string, unknown>

interface ReceiveChain {
  receive(status: "ok" | "error" | "timeout", callback: (payload: RealtimePayload) => void): ReceiveChain
}

interface ChannelLike {
  on(event: string, callback: (payload: RealtimePayload) => void): void
  onClose?(callback: (payload: unknown) => void): void
  onError?(callback: (payload: unknown) => void): void
  join(): ReceiveChain
  push(event: string, payload: RealtimePayload, timeout: number): ReceiveChain
  leave(): void
}

interface SocketLike {
  channel(topic: string, params: RealtimePayload): ChannelLike
  connect(): void
  disconnect(callback?: () => void): void
  connectionState?(): string
  onOpen?(callback: () => void): void
  onClose?(callback: (event: unknown) => void): void
  onError?(callback: (error: unknown) => void): void
}

export interface SocketConstructor {
  new (path: string, options: {longPollFallbackMs: number; params: {_csrf_token?: string | null}}): SocketLike
}

export interface RealtimeHandlers {
  onOpen?(): void
  onClose?(event: unknown): void
  onError?(error: unknown): void
  onJoinOk?(payload: RealtimePayload): void
  onJoinError?(payload: RealtimePayload): void
  onJoinTimeout?(): void
  onChannelClose?(payload: unknown): void
  onChannelError?(payload: unknown): void
  onBufferMessage?(payload: ChatMessage): void
  onBufferRead?(payload: BufferReadPayload): void
  onBufferLeft?(payload: BufferLeftPayload): void
  onBufferJoined?(payload: BufferJoinedPayload): void
  onDirectMessageThread?(payload: DirectMessageThreadPayload): void
  onDirectMessageClosed?(payload: DirectMessageClosedPayload): void
  onServerStatus?(payload: ServerStatusPayload): void
  onPresenceSync?(payload: PresenceSyncPayload): void
  onPresenceDiff?(payload: PresenceDiffPayload): void
  onNotificationPreference?(payload: NotificationPreferenceEventPayload): void
}

interface RealtimeClientOptions {
  SocketClass?: SocketConstructor
  csrfToken?: string | null
  userId?: string | number
  handlers?: RealtimeHandlers
  socketPath?: string
  pushTimeout?: number
  longPollFallbackMs?: number
}

export function createRealtimeClient({
  SocketClass,
  csrfToken,
  userId,
  handlers = {},
  socketPath = "/socket",
  pushTimeout = 10_000,
  longPollFallbackMs = 2500,
}: RealtimeClientOptions = {}) {
  if (!SocketClass) throw new Error("SocketClass is required")

  const socket = new SocketClass(socketPath, {
    longPollFallbackMs,
    params: {_csrf_token: csrfToken},
  })
  const channel = socket.channel(`user:${userId}`, {})
  let joinedOnce = false

  socket.onOpen?.(() => handlers.onOpen?.())
  socket.onClose?.((event) => handlers.onClose?.(event))
  socket.onError?.((error) => handlers.onError?.(error))
  channel.onClose?.((payload) => handlers.onChannelClose?.(payload))
  channel.onError?.((payload) => handlers.onChannelError?.(payload))

  channel.on("buffer:message", (payload) => {
    const message = canonicalChatMessage(payload)
    if (message) handlers.onBufferMessage?.(message)
  })
  channel.on("buffer:error", (payload) => {
    const message = canonicalChatMessage(payload)
    if (message) handlers.onBufferMessage?.(message)
  })
  channel.on("buffer:system", (payload) => {
    const message = canonicalChatMessage(payload)
    if (message) handlers.onBufferMessage?.(message)
  })
  channel.on("buffer:read", (payload) => {
    if (validBufferReadPayload(payload)) handlers.onBufferRead?.(payload)
  })
  channel.on("buffer:left", (payload) => {
    if (validBufferLeftPayload(payload)) handlers.onBufferLeft?.(payload)
  })
  channel.on("buffer:joined", (payload) => {
    if (validBufferJoinedPayload(payload)) handlers.onBufferJoined?.(payload)
  })
  channel.on("direct_message:thread", (payload) => {
    if (validDirectMessageThreadPayload(payload)) handlers.onDirectMessageThread?.(payload)
  })
  channel.on("direct_message:closed", (payload) => {
    if (validDirectMessageClosedPayload(payload)) handlers.onDirectMessageClosed?.(payload)
  })
  channel.on("server:status", (payload) => {
    if (validServerStatusPayload(payload)) handlers.onServerStatus?.(payload)
  })
  channel.on("presence:sync", (payload) => {
    if (validPresenceSyncPayload(payload)) handlers.onPresenceSync?.(payload)
  })
  channel.on("presence:diff", (payload) => {
    if (validPresenceDiffPayload(payload)) handlers.onPresenceDiff?.(payload)
  })
  channel.on("notification:preference", (payload) => {
    if (validNotificationPreferenceEventPayload(payload)) handlers.onNotificationPreference?.(payload)
  })

  function connect() {
    socket.connect()
    if (!joinedOnce) {
      joinedOnce = true
      joinChannel()
    }

    return client
  }

  function joinChannel() {
    channel
      .join()
      .receive("ok", (payload) => handlers.onJoinOk?.(payload))
      .receive("error", (payload) => handlers.onJoinError?.(payload))
      .receive("timeout", () => handlers.onJoinTimeout?.())
  }

  function push<T = RealtimePayload>(
    event: string,
    payload: RealtimePayload = {},
    timeout = pushTimeout
  ): Promise<T> {
    return new Promise<T>((resolve, reject) => {
      channel
        .push(event, payload, timeout)
        .receive("ok", (reply) => resolve(reply as T))
        .receive("error", reject)
        .receive("timeout", () => reject({reply: "timeout", reason: "timeout"}))
    })
  }

  function disconnect() {
    channel.leave()
    socket.disconnect()
  }

  function reconnect() {
    socket.disconnect(() => socket.connect())
    return client
  }

  function connectionState() {
    return typeof socket.connectionState === "function" ? socket.connectionState() : "unknown"
  }

  const client = {connect, push, disconnect, reconnect, connectionState, socket, channel}
  return client
}

export type RealtimeClient = ReturnType<typeof createRealtimeClient>
