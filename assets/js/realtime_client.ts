export type RealtimePayload = Record<string, unknown>

interface ReceiveChain {
  receive(status: "ok" | "error" | "timeout", callback: (payload: RealtimePayload) => void): ReceiveChain
}

interface ChannelLike {
  on(event: string, callback: (payload: RealtimePayload) => void): void
  join(): ReceiveChain
  push(event: string, payload: RealtimePayload, timeout: number): ReceiveChain
  leave(): void
}

interface SocketLike {
  channel(topic: string, params: RealtimePayload): ChannelLike
  connect(): void
  disconnect(): void
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
  onMessage?(payload: RealtimePayload): void
  onMention?(payload: RealtimePayload): void
  onBufferMessage?(payload: RealtimePayload): void
  onBufferRead?(payload: RealtimePayload): void
  onBufferLeft?(payload: RealtimePayload): void
  onBufferJoined?(payload: RealtimePayload): void
  onServerStatus?(payload: RealtimePayload): void
  onPresenceSync?(payload: RealtimePayload): void
  onPresenceDiff?(payload: RealtimePayload): void
  onNotificationMention?(payload: RealtimePayload): void
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

  socket.onOpen?.(() => handlers.onOpen?.())
  socket.onClose?.((event) => handlers.onClose?.(event))
  socket.onError?.((error) => handlers.onError?.(error))

  channel.on("message", (payload) => handlers.onMessage?.(payload))
  channel.on("mention", (payload) => handlers.onMention?.(payload))
  channel.on("buffer:message", (payload) => handlers.onBufferMessage?.(payload))
  channel.on("buffer:error", (payload) => handlers.onBufferMessage?.(payload))
  channel.on("buffer:system", (payload) => handlers.onBufferMessage?.(payload))
  channel.on("buffer:read", (payload) => handlers.onBufferRead?.(payload))
  channel.on("buffer:left", (payload) => handlers.onBufferLeft?.(payload))
  channel.on("buffer:joined", (payload) => handlers.onBufferJoined?.(payload))
  channel.on("server:status", (payload) => handlers.onServerStatus?.(payload))
  channel.on("presence:sync", (payload) => handlers.onPresenceSync?.(payload))
  channel.on("presence:diff", (payload) => handlers.onPresenceDiff?.(payload))
  channel.on("notification:mention", (payload) => handlers.onNotificationMention?.(payload))

  function connect() {
    socket.connect()
    joinChannel()

    return client
  }

  function joinChannel() {
    channel
      .join()
      .receive("ok", (payload) => handlers.onJoinOk?.(payload))
      .receive("error", (payload) => handlers.onJoinError?.(payload))
      .receive("timeout", () => handlers.onJoinTimeout?.())
  }

  function push<T extends RealtimePayload = RealtimePayload>(
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
    disconnect()
    return connect()
  }

  function connectionState() {
    return typeof socket.connectionState === "function" ? socket.connectionState() : "unknown"
  }

  const client = {connect, push, disconnect, reconnect, connectionState, socket, channel}
  return client
}

export type RealtimeClient = ReturnType<typeof createRealtimeClient>
