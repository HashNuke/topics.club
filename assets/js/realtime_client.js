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

  channel.on("message", (payload) => handlers.onMessage?.(payload))
  channel.on("mention", (payload) => handlers.onMention?.(payload))
  channel.on("buffer:message", (payload) => handlers.onBufferMessage?.(payload))
  channel.on("buffer:read", (payload) => handlers.onBufferRead?.(payload))
  channel.on("server:status", (payload) => handlers.onServerStatus?.(payload))
  channel.on("presence:sync", (payload) => handlers.onPresenceSync?.(payload))
  channel.on("presence:diff", (payload) => handlers.onPresenceDiff?.(payload))
  channel.on("notification:mention", (payload) => handlers.onNotificationMention?.(payload))

  function connect() {
    socket.connect()

    channel
      .join()
      .receive("ok", (payload) => handlers.onJoinOk?.(payload))
      .receive("error", (payload) => handlers.onJoinError?.(payload))
      .receive("timeout", () => handlers.onJoinTimeout?.())

    return client
  }

  function push(event, payload = {}, timeout = pushTimeout) {
    return new Promise((resolve, reject) => {
      channel
        .push(event, payload, timeout)
        .receive("ok", resolve)
        .receive("error", reject)
        .receive("timeout", () => reject({reason: "timeout"}))
    })
  }

  function disconnect() {
    channel.leave()
    socket.disconnect()
  }

  function connectionState() {
    return typeof socket.connectionState === "function" ? socket.connectionState() : "unknown"
  }

  const client = {connect, push, disconnect, connectionState, socket, channel}
  return client
}
