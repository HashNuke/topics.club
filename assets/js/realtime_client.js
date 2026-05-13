export function createRealtimeClient({
  SocketClass,
  csrfToken,
  userId,
  handlers = {},
  socketPath = "/socket",
  pushTimeout = 10_000,
} = {}) {
  if (!SocketClass) throw new Error("SocketClass is required")

  const socket = new SocketClass(socketPath, {params: {_csrf_token: csrfToken}})
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

  function push(event, payload = {}, timeout = pushTimeout) {
    return new Promise((resolve, reject) => {
      channel
        .push(event, payload, timeout)
        .receive("ok", resolve)
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
