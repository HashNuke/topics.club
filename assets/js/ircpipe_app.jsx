import React, {useEffect, useMemo, useRef, useState} from "react"
import {FloatingArrow, arrow, offset, shift, useFloating} from "@floating-ui/react"
import {createApiClient} from "./api_client.js"

const csrfToken = document.querySelector("meta[name='csrf-token']")?.getAttribute("content")
export const MESSAGE_RENDER_LIMIT = 400

export const demoTopics = [
  {
    id: "local-elixir",
    name: "#elixir",
    description: "Phoenix, OTP, releases, and production Elixir help.",
    server_host: "127.0.0.1",
    server_port: 6667,
    use_tls: false,
    channel: "#elixir",
    members: 426,
    vibe: "builders",
  },
  {
    id: "local-phoenix",
    name: "#phoenix",
    description: "LiveView patterns, web UI questions, and framework support.",
    server_host: "127.0.0.1",
    server_port: 6667,
    use_tls: false,
    channel: "#phoenix",
    members: 188,
    vibe: "web",
  },
  {
    id: "local-linux",
    name: "#linux",
    description: "Daily Linux discussion, troubleshooting, and desktop setups.",
    server_host: "127.0.0.1",
    server_port: 6667,
    use_tls: false,
    channel: "#linux",
    members: 931,
    vibe: "systems",
  },
  {
    id: "local-rust",
    name: "#rust",
    description: "Rust language help, async crates, and compiler talk.",
    server_host: "127.0.0.1",
    server_port: 6667,
    use_tls: false,
    channel: "#rust",
    members: 812,
    vibe: "language",
  },
  {
    id: "local-gamedev",
    name: "#gamedev",
    description: "Indie games, engines, shaders, and release feedback.",
    server_host: "127.0.0.1",
    server_port: 6667,
    use_tls: false,
    channel: "#gamedev",
    members: 147,
    vibe: "creative",
  },
  {
    id: "local-homelab",
    name: "#homelab",
    description: "Self-hosting, small servers, storage, and network projects.",
    server_host: "127.0.0.1",
    server_port: 6667,
    use_tls: false,
    channel: "#homelab",
    members: 269,
    vibe: "infra",
  },
]

const demoUsers = [
  {nick: "mira", role: "op", status: "online"},
  {nick: "patch", role: "voice", status: "online"},
  {nick: "samir", status: "online"},
  {nick: "lena", status: "away"},
  {nick: "jo", status: "online"},
  {nick: "rootless", status: "online"},
  {nick: "nora", status: "away"},
  {nick: "kai", status: "online"},
]

const demoMessages = [
  {
    id: 1,
    occurredAt: "2026-05-13T09:41:00Z",
    nick: "mira",
    body: "The trick is to keep the process boundary boring and let the UI stay optimistic.",
  },
  {
    id: 2,
    occurredAt: "2026-05-13T09:42:00Z",
    nick: "patch",
    body: "That sounds right. A reconnect should replay the joined rooms, not ask the user again.",
  },
  {
    id: 3,
    occurredAt: "2026-05-13T09:44:00Z",
    nick: "samir",
    body: "Can we surface server state without making people learn network details on day one?",
  },
  {
    id: 4,
    occurredAt: "2026-05-13T09:45:00Z",
    nick: "topics.club",
    body: "mira joined from the web client",
    kind: "system",
  },
  {
    id: 5,
    occurredAt: "2026-05-13T10:17:00Z",
    nick: "lena",
    body: "Two-line topic names help a lot. The channel is obvious, and the server stays quiet.",
  },
]

export const slashCommands = [
  {name: "/join", usage: "/join #channel", description: "Join a channel"},
  {name: "/part", usage: "/part #channel", description: "Leave a channel"},
  {name: "/leave", usage: "/leave #channel", description: "Leave a channel"},
  {name: "/msg", usage: "/msg nick message", description: "Send a private message"},
  {name: "/me", usage: "/me action", description: "Send an action message"},
  {name: "/nick", usage: "/nick newnick", description: "Change nickname"},
  {name: "/topic", usage: "/topic #channel text", description: "Set or view a topic"},
  {name: "/quote", usage: "/quote RAW COMMAND", description: "Send a raw IRC command"},
]

export default function IrcpipeApp({apiClient: providedApiClient, appMode, currentUser, developerOauth, realtimeClientFactory}) {
  const apiClient = useMemo(() => providedApiClient || createApiClient({csrfToken}), [providedApiClient])
  const mode = appMode || (currentUser ? "chat" : "landing")
  const [topics, setTopics] = useState(demoTopics)
  const [authTopic, setAuthTopic] = useState(null)
  const [view, setView] = useState("chat")
  const [notificationState, setNotificationState] = useState(notificationPermission())
  const [connectionHealth, setConnectionHealth] = useState("disconnected")
  const [connections, setConnections] = useState(() => initialConnections())
  const [activeChannelId, setActiveChannelId] = useState("chan-elixir")
  const [activeServerId, setActiveServerId] = useState("server-local")
  const [messagesByChannel, setMessagesByChannel] = useState(() => ({
    "chan-elixir": demoMessages,
  }))
  const [messagesByServer, setMessagesByServer] = useState(() =>
    Object.fromEntries(initialConnections().map((connection) => [connection.id, serverBufferMessages(connection)]))
  )
  const [usersByChannel, setUsersByChannel] = useState({})
  const [draft, setDraft] = useState("")
  const loadingOlderRef = useRef(new Set())
  const readingBuffersRef = useRef(new Set())
  const activeChannelIdRef = useRef(activeChannelId)
  const activeServerIdRef = useRef(activeServerId)
  const connectionsRef = useRef(connections)
  const realtimeClientRef = useRef(null)
  const notificationStateRef = useRef(notificationState)

  useEffect(() => {
    connectionsRef.current = connections
  }, [connections])

  useEffect(() => {
    activeChannelIdRef.current = activeChannelId
  }, [activeChannelId])

  useEffect(() => {
    activeServerIdRef.current = activeServerId
  }, [activeServerId])

  useEffect(() => {
    notificationStateRef.current = notificationState
  }, [notificationState])

  useEffect(() => {
    apiClient
      .topics()
      .then(({topics}) => {
        if (topics?.length >= demoTopics.length) setTopics(topics.map(normalizeTopic))
      })
      .catch(() => setTopics(demoTopics))
  }, [apiClient])

  useEffect(() => {
    if (!currentUser || mode === "landing") return

    apiClient
      .bootstrap()
      .then((bootstrap) => applyBootstrap(bootstrap))
      .catch(() => {})
  }, [apiClient, currentUser?.id, mode])

  useEffect(() => {
    if (!currentUser || mode === "landing" || !realtimeClientFactory) return

    const realtimeClient = realtimeClientFactory({
      handlers: {
        onMessage: applyRealtimeMessage,
        onMention: handleMentionNotification,
        onBufferMessage: applyRealtimeMessage,
        onBufferJoined: applyJoinedTopic,
        onBufferLeft: applyBufferLeft,
        onBufferRead: applyBufferRead,
        onPresenceDiff: applyPresenceDiff,
        onPresenceSync: applyPresenceSync,
        onServerStatus: applyServerStatus,
        onNotificationMention: handleMentionNotification,
        onOpen: () => setConnectionHealth("connected"),
        onClose: () => setConnectionHealth("reconnecting"),
        onError: () => setConnectionHealth("degraded"),
        onJoinOk: () => setConnectionHealth("connected"),
        onJoinError: () => setConnectionHealth("degraded"),
        onJoinTimeout: () => setConnectionHealth("degraded"),
      },
    })

    realtimeClientRef.current = realtimeClient.connect()

    return () => {
      realtimeClient.disconnect()
      realtimeClientRef.current = null
      setConnectionHealth("disconnected")
    }
  }, [currentUser?.id, mode, realtimeClientFactory])

  const channels = useMemo(
    () => connections.flatMap((connection) => connection.channels.map((channel) => ({...channel, connection}))),
    [connections]
  )

  const activeChannel = channels.find((channel) => channel.id === activeChannelId) || channels[0]
  const activeServer = connections.find((connection) => connection.id === activeServerId) || connections[0]
  const messages = activeChannel ? messagesByChannel[activeChannel.id] || [] : []
  const serverMessages = activeServer ? messagesByServer[activeServer.id] || serverBufferMessages(activeServer) : []
  const users = activeChannel ? usersByChannel[activeChannel.id] || demoUsers : []

  function selectTopic(topic) {
    if (mode === "landing" && currentUser) {
      window.location.href = `/chat?topic=${encodeURIComponent(topic.id)}`
      return
    }

    if (!currentUser) {
      setAuthTopic(topic)
      return
    }

    joinTopic(topic)
  }

  async function joinTopic(topic) {
    const normalized = normalizeTopic(topic)

    if (currentUser && Number.isInteger(Number(normalized.id))) {
      try {
        const joined = await apiClient.joinTopic(normalized.id)
        applyJoinedTopic(joined)
        return
      } catch (_error) {
        // Keep the prototype usable when the backend is unavailable in design-only runs.
      }
    }

    joinTopicLocally(normalized)
  }

  function joinTopicLocally(normalized) {
    const connectionKey = normalized.server_host
    const channelId = `${connectionKey}-${normalized.channel}`.replace(/[^a-z0-9]+/gi, "-").toLowerCase()

    setConnections((current) => {
      const existingConnection = current.find((connection) => connection.host === connectionKey)
      const newChannel = {
        id: channelId,
        channel: normalized.channel,
        topic: normalized.description,
        unread_count: 0,
        mention_count: 0,
      }

      if (existingConnection) {
        return current.map((connection) => {
          if (connection.id !== existingConnection.id) return connection
          if (connection.channels.some((channel) => channel.channel === normalized.channel)) return connection
          return {...connection, channels: [...connection.channels, newChannel]}
        })
      }

      return [
        ...current,
        {
          id: `server-${connectionKey}`,
          name: normalized.server_host,
          host: normalized.server_host,
          status: "connected",
          channels: [newChannel],
        },
      ]
    })

    setMessagesByChannel((current) => ({
      ...current,
      [channelId]: current[channelId] || seededMessagesFor(normalized),
    }))
    setActiveChannelId(channelId)
    setView("chat")
  }

  function applyJoinedTopic({connection, buffer, topic}) {
    if (!connection || !buffer) return

    const connectionId = `server:${connection.id}`
    const channel = {
      id: buffer.buffer_id,
      channel_membership_id: buffer.channel_membership_id,
      channel: buffer.title,
      topic: topic?.description || buffer.subtitle,
      unread_count: buffer.unread_count,
      mention_count: buffer.mention_count,
    }

    setConnections((current) => {
      const existingConnection = current.find((item) => item.server_connection_id === connection.id || item.id === connectionId)

      if (existingConnection) {
        return current.map((item) => {
          if (item.id !== existingConnection.id) return item
          if (item.channels.some((existing) => existing.id === channel.id)) return item
          return {...item, channels: [...item.channels, channel]}
        })
      }

      return [
        ...current,
        {
          id: connectionId,
          server_connection_id: connection.id,
          name: connection.name,
          host: connection.host,
          port: connection.port,
          use_tls: connection.use_tls,
          nickname: connection.nickname,
          status: connection.status,
          channels: [channel],
        },
      ]
    })

    setMessagesByChannel((current) => ({
      ...current,
      [channel.id]:
        current[channel.id] ||
        seededMessagesFor({
          id: topic?.id || channel.id,
          channel: channel.channel,
          server_host: connection.host,
        }),
    }))
    setActiveServerId(connectionId)
    setActiveChannelId(channel.id)
    setView("chat")
  }

  function joinManualServer(form) {
    const host = form.host.trim()
    const channels = String(form.channels || "")
      .split(",")
      .map((channel) => normalizeChannel(channel.trim()))
      .filter(Boolean)

    if (!host || channels.length === 0) return

    channels.forEach((channel) => {
      joinTopic({
        id: `${host}-${channel}`,
        name: channel,
        description: `A channel you joined directly on ${host}.`,
        server_host: host,
        server_port: Number(form.port) || 6667,
        use_tls: form.useTls,
        channel,
      })
    })
  }

  async function sendMessage(event) {
    event.preventDefault()
    if (!draft.trim() || !activeChannel) return

    const body = draft.trim()
    if (isRealtimeChannel(activeChannel) && realtimeClientRef.current && connectionHealth !== "connected") return

    if (body.startsWith("/") && realtimeClientRef.current) {
      setDraft("")

      try {
        await realtimeClientRef.current.push("command:run", {
          input: body,
          buffer_id: currentBufferId(),
        })

        appendSystemMessage("Command accepted.")
      } catch (_error) {
        appendSystemMessage("Command failed.")
      }

      return
    }

    const nextMessage = {
      id: `${view}-${Date.now()}`,
      occurredAt: new Date().toISOString(),
      nick: currentUser?.email?.split("@")[0] || "you",
      body,
    }

    if (view === "server" && activeServer) {
      setMessagesByServer((current) => ({
        ...current,
        [activeServer.id]: [...(current[activeServer.id] || serverBufferMessages(activeServer)), nextMessage],
      }))
      setDraft("")
      return
    }

    if (realtimeClientRef.current && activeChannel.id?.startsWith("channel:")) {
      const clientMessageId = `client-${Date.now()}`
      const pendingMessage = {...nextMessage, id: clientMessageId, clientMessageId, pending: true}

      setMessagesByChannel((current) => ({
        ...current,
        [activeChannel.id]: [...(current[activeChannel.id] || []), pendingMessage],
      }))
      setDraft("")

      try {
        const reply = await realtimeClientRef.current.push("message:send", {
          client_message_id: clientMessageId,
          buffer_id: activeChannel.id,
          body,
        })

        replacePendingMessage(activeChannel.id, clientMessageId, normalizeMessage(reply.message))
      } catch (_error) {
        markPendingFailed(activeChannel.id, clientMessageId)
      }

      return
    }

    setMessagesByChannel((current) => ({
      ...current,
      [activeChannel.id]: [...(current[activeChannel.id] || []), nextMessage],
    }))
    setDraft("")
  }

  async function retryMessage(message) {
    if (!activeChannel || !isRealtimeChannel(activeChannel) || !realtimeClientRef.current || connectionHealth !== "connected") return

    const clientMessageId = `client-${Date.now()}`
    const pendingMessage = {
      ...message,
      id: clientMessageId,
      clientMessageId,
      occurredAt: new Date().toISOString(),
      pending: true,
      failed: false,
    }

    setMessagesByChannel((current) => ({
      ...current,
      [activeChannel.id]: (current[activeChannel.id] || []).map((currentMessage) =>
        currentMessage.id === message.id ? pendingMessage : currentMessage
      ),
    }))

    try {
      const reply = await realtimeClientRef.current.push("message:send", {
        client_message_id: clientMessageId,
        buffer_id: activeChannel.id,
        body: message.body,
      })

      replacePendingMessage(activeChannel.id, clientMessageId, normalizeMessage(reply.message))
    } catch (_error) {
      markPendingFailed(activeChannel.id, clientMessageId)
    }
  }

  function currentBufferId() {
    if (view === "server" && activeServer) return `server:${activeServer.server_connection_id || activeServer.id}`
    return activeChannel?.id
  }

  function appendSystemMessage(body) {
    const message = {
      id: `system-${Date.now()}`,
      occurredAt: new Date().toISOString(),
      nick: "topics.club",
      body,
      kind: "system",
    }

    if (view === "server" && activeServer) {
      setMessagesByServer((current) => ({
        ...current,
        [activeServer.id]: appendTimelineMessage(
          current[activeServer.id] || serverBufferMessages(activeServer),
          message,
          readingBuffersRef.current.has(activeServer.id)
        ),
      }))
      return
    }

    if (!activeChannel) return

    setMessagesByChannel((current) => ({
      ...current,
      [activeChannel.id]: appendTimelineMessage(current[activeChannel.id] || [], message, readingBuffersRef.current.has(activeChannel.id)),
    }))
  }

  async function loadOlderMessages(bufferId) {
    if (!bufferId || loadingOlderRef.current.has(bufferId)) return

    const currentMessages = bufferId.startsWith("server:")
      ? messagesByServer[bufferId] || []
      : messagesByChannel[bufferId] || []
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

  async function requestNotifications() {
    if (!("Notification" in window)) {
      setNotificationState("unsupported")
      return
    }

    const permission = await Notification.requestPermission()
    setNotificationState(permission)
  }

  function applyRealtimeMessage(message) {
    const normalized = normalizeMessage(message)
    const bufferId = normalized.buffer_id || (normalized.channel_membership_id ? `channel:${normalized.channel_membership_id}` : null)
    if (!bufferId) return

    if (bufferId.startsWith("server:")) {
      setMessagesByServer((current) => ({
        ...current,
        [bufferId]: appendTimelineMessage(current[bufferId] || [], normalized, readingBuffersRef.current.has(bufferId)),
      }))
      return
    }

    setMessagesByChannel((current) => ({
      ...current,
      [bufferId]: appendTimelineMessage(current[bufferId] || [], normalized, readingBuffersRef.current.has(bufferId)),
    }))
  }

  function updateBufferReadingState(bufferId, readingOlder) {
    if (!bufferId) return

    if (readingOlder) {
      readingBuffersRef.current.add(bufferId)
      return
    }

    if (!readingBuffersRef.current.has(bufferId)) return

    readingBuffersRef.current.delete(bufferId)
    pruneBufferMessages(bufferId)
  }

  function pruneBufferMessages(bufferId) {
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

  function applyServerStatus(payload) {
    setConnections((current) =>
      current.map((connection) =>
        connection.server_connection_id === payload.server_connection_id ? {...connection, status: payload.status} : connection
      )
    )
  }

  function applyPresenceSync(payload) {
    setUsersByChannel((current) => ({
      ...current,
      [payload.buffer_id]: payload.users || [],
    }))
  }

  function applyPresenceDiff(payload) {
    setUsersByChannel((current) => ({
      ...current,
      [payload.buffer_id]: applyUserDiff(current[payload.buffer_id] || [], payload.diff),
    }))
  }

  function applyBufferLeft(payload) {
    const bufferId = payload.buffer_id
    if (bufferId?.startsWith("server:")) {
      applyServerDeleted({server_connection_id: payload.server_connection_id})
      return
    }

    const channelId = bufferId?.startsWith("channel:") ? bufferId : null
    if (!channelId) return

    setConnections((current) =>
      current.map((connection) => ({
        ...connection,
        channels: connection.channels.filter((channel) => channel.id !== channelId),
      }))
    )
    setMessagesByChannel((current) => {
      const next = {...current}
      delete next[channelId]
      return next
    })
    setUsersByChannel((current) => {
      const next = {...current}
      delete next[channelId]
      return next
    })

    if (activeChannelIdRef.current === channelId) {
      const nextServerId = `server:${payload.server_connection_id}`
      setActiveServerId(nextServerId)
      setView("server")
    }
  }

  function applyBufferRead(payload) {
    const bufferId = payload?.buffer_id
    if (!bufferId) return

    setConnections((current) =>
      current.map((connection) => {
        if (connection.id === bufferId) {
          return {
            ...connection,
            unread_count: payload.unread_count ?? 0,
            mention_count: payload.mention_count ?? 0,
          }
        }

        return {
          ...connection,
          channels: connection.channels.map((channel) =>
            channel.id === bufferId
              ? {
                  ...channel,
                  unread_count: payload.unread_count ?? 0,
                  mention_count: payload.mention_count ?? 0,
                }
              : channel
          ),
        }
      })
    )
  }

  function handleMentionNotification(message) {
    if (!("Notification" in window)) return
    if (document.visibilityState !== "hidden") return
    if (notificationStateRef.current !== "granted" && window.Notification.permission !== "granted") return
    if (message.nick === currentUser?.email?.split("@")[0]) return

    new window.Notification(message.channel || "topics.club", {body: `${message.nick}: ${message.body}`})
  }

  function replacePendingMessage(channelId, clientMessageId, message) {
    setMessagesByChannel((current) => ({
      ...current,
      [channelId]: (current[channelId] || []).map((currentMessage) =>
        currentMessage.clientMessageId === clientMessageId ? message : currentMessage
      ),
    }))
  }

  function markPendingFailed(channelId, clientMessageId) {
    setMessagesByChannel((current) => ({
      ...current,
      [channelId]: (current[channelId] || []).map((currentMessage) =>
        currentMessage.clientMessageId === clientMessageId ? {...currentMessage, pending: false, failed: true} : currentMessage
      ),
    }))
  }

  function applyBootstrap(bootstrap) {
    if (!bootstrap?.buffers || !bootstrap?.connections) return

    if (bootstrap.topics?.length) setTopics(bootstrap.topics.map(normalizeTopic))
    if (bootstrap.notification_state) setNotificationState(bootstrap.notification_state)

    const nextConnections = bootstrap.connections.map((connection) => {
      const channelBuffers = bootstrap.buffers.filter(
        (buffer) => buffer.buffer_type === "channel" && buffer.server_connection_id === connection.id
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
        channels: channelBuffers.map((buffer) => ({
          id: buffer.buffer_id,
          channel_membership_id: buffer.channel_membership_id,
          channel: buffer.title,
          topic: buffer.subtitle,
          unread_count: buffer.unread_count,
          mention_count: buffer.mention_count,
        })),
      }
    })

    if (nextConnections.length > 0) {
      setConnections(nextConnections)
      setMessagesByServer(
        Object.fromEntries(
          nextConnections.map((connection) => [
            connection.id,
            (bootstrap.messages_by_buffer || {})[connection.id]?.map(normalizeMessage) || serverBufferMessages(connection),
          ])
        )
      )
    }

    setMessagesByChannel(
      Object.fromEntries(
        Object.entries(bootstrap.messages_by_buffer || {}).map(([bufferId, messages]) => [
          bufferId,
          messages.map(normalizeMessage),
        ])
      )
    )
    setUsersByChannel(bootstrap.users_by_buffer || {})

    if (bootstrap.active_buffer_id?.startsWith("channel:")) {
      setActiveChannelId(bootstrap.active_buffer_id)
      const activeConnection = nextConnections.find((connection) =>
        connection.channels.some((channel) => channel.id === bootstrap.active_buffer_id)
      )
      if (activeConnection) setActiveServerId(activeConnection.id)
    } else if (bootstrap.active_buffer_id?.startsWith("server:")) {
      setActiveServerId(bootstrap.active_buffer_id)
      setView("server")
    }
  }

  if (mode === "landing") {
    return (
      <LandingPage
        currentUser={currentUser}
        topics={topics}
        developerOauth={developerOauth}
        selectedTopic={authTopic}
        onSelectTopic={selectTopic}
        onCloseAuth={() => setAuthTopic(null)}
      />
    )
  }

  if (!currentUser) {
    return (
      <LandingPage
        currentUser={null}
        topics={topics}
        developerOauth={developerOauth}
        selectedTopic={authTopic}
        onSelectTopic={selectTopic}
        onCloseAuth={() => setAuthTopic(null)}
      />
    )
  }

  return (
    <AppShell
      activeChannel={activeChannel}
      activeServer={activeServer}
      connections={connections}
      currentUser={currentUser}
      draft={draft}
      messages={messages}
      notificationState={notificationState}
      serverMessages={serverMessages}
      topics={topics}
      users={users}
      view={view}
      onDiscover={() => setView("discover")}
      onJoinManualServer={joinManualServer}
      onLeaveChannel={leaveChannel}
      onMarkChannelRead={markChannelRead}
      onRequestNotifications={requestNotifications}
      onDisconnectServer={disconnectServer}
      onLeaveServer={leaveServer}
      onReconnectServer={reconnectServer}
      onUpdateServer={updateServerConnection}
      onSelectChannel={(channel) => {
        setActiveServerId(channel.connection?.id || activeServerId)
        setActiveChannelId(channel.id)
        setView("chat")
      }}
      onSelectServer={(server) => {
        setActiveServerId(server.id)
        setView("server")
      }}
      onSelectTopic={selectTopic}
      onRetryMessage={retryMessage}
      onSendMessage={sendMessage}
      onLoadOlderMessages={loadOlderMessages}
      onReadingStateChange={updateBufferReadingState}
      onShowChat={() => setView("chat")}
      onUpdateDraft={setDraft}
      connectionHealth={connectionHealth}
    />
  )

  async function markChannelRead(channel) {
    if (!channel?.id || !realtimeClientRef.current) return

    try {
      await realtimeClientRef.current.push("buffer:read", {buffer_id: channel.id})
      setConnections((current) =>
        current.map((connection) => ({
          ...connection,
          channels: connection.channels.map((currentChannel) =>
            currentChannel.id === channel.id
              ? {...currentChannel, unread_count: 0, mention_count: 0}
              : currentChannel
          ),
        }))
      )
    } catch (_error) {
      // Keep counters as-is if the backend rejects the read marker.
    }
  }

  async function leaveChannel(channel) {
    if (!channel?.id || !realtimeClientRef.current) return

    try {
      const left = await realtimeClientRef.current.push("channel:leave", {buffer_id: channel.id})
      applyBufferLeft(left)
    } catch (_error) {
      // The channel remains visible if the backend cannot leave it.
    }
  }

  async function reconnectServer(server) {
    if (!server?.server_connection_id || !realtimeClientRef.current) return

    try {
      const status = await realtimeClientRef.current.push("server:reconnect", {
        server_connection_id: server.server_connection_id,
      })
      applyServerStatus(status)
    } catch (_error) {
      // Keep the current server status if reconnect fails.
    }
  }

  async function disconnectServer(server) {
    if (!server?.server_connection_id || !realtimeClientRef.current) return

    try {
      const status = await realtimeClientRef.current.push("server:disconnect", {
        server_connection_id: server.server_connection_id,
      })
      applyServerStatus(status)
    } catch (_error) {
      // Keep the current server status if disconnect fails.
    }
  }

  async function leaveServer(server) {
    if (!server?.server_connection_id) return

    try {
      const {deleted} = await apiClient.deleteConnection(server.server_connection_id)
      applyServerDeleted(deleted || {server_connection_id: server.server_connection_id})
    } catch (_error) {
      // Keep the server visible if deletion fails.
    }
  }

  async function updateServerConnection(server, form) {
    if (!server?.server_connection_id) return

    const host = form.host.trim()
    const nickname = form.nickname.trim()
    if (!host || !nickname) return

    try {
      const {connection} = await apiClient.updateConnection(server.server_connection_id, {
        name: server.name || host,
        host,
        port: Number(form.port) || 6667,
        use_tls: form.useTls,
        nickname,
      })
      applyUpdatedConnection(connection)
    } catch (_error) {
      // Leave the current connection details visible if the backend rejects the edit.
    }
  }

  function applyUpdatedConnection(connection) {
    if (!connection?.id) return

    setConnections((current) =>
      current.map((server) =>
        server.server_connection_id === connection.id
          ? {
              ...server,
              name: connection.name,
              host: connection.host,
              port: connection.port,
              use_tls: connection.use_tls,
              nickname: connection.nickname,
              status: connection.status,
              channels: server.channels.map((channel) => ({
                ...channel,
                topic: channel.topic === `on ${server.host}` ? `on ${connection.host}` : channel.topic,
              })),
            }
          : server
      )
    )
  }

  function applyServerDeleted(payload) {
    const deletedId = `server:${payload.server_connection_id}`
    const currentConnections = connectionsRef.current
    const deletedServer = currentConnections.find(
      (server) => server.id === deletedId || server.server_connection_id === payload.server_connection_id
    )
    if (!deletedServer) return

    const deletedChannelIds = new Set(deletedServer.channels.map((channel) => channel.id))
    const nextConnections = currentConnections.filter((server) => server.id !== deletedServer.id)
    const nextServer = nextConnections[0]
    const nextChannel = nextServer?.channels[0]

    connectionsRef.current = nextConnections
    setConnections(nextConnections)
    setMessagesByServer((current) => {
      const next = {...current}
      delete next[deletedServer.id]
      return next
    })
    setMessagesByChannel((current) => {
      const next = {...current}
      deletedChannelIds.forEach((channelId) => delete next[channelId])
      return next
    })
    setUsersByChannel((current) => {
      const next = {...current}
      deletedChannelIds.forEach((channelId) => delete next[channelId])
      return next
    })

    if (activeServerIdRef.current === deletedServer.id || deletedChannelIds.has(activeChannelIdRef.current)) {
      if (nextChannel) {
        setActiveServerId(nextServer.id)
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
}

export function LandingPage({currentUser, topics, developerOauth, selectedTopic, onSelectTopic, onCloseAuth}) {
  return (
    <main className="min-h-screen bg-[#090b10] text-slate-100">
      <section className="mx-auto grid min-h-screen max-w-7xl content-center gap-8 px-5 py-8 lg:grid-cols-[0.9fr_1.1fr]">
        <div className="self-center">
          <div className="mb-8 flex items-center gap-3">
            <AppMark />
            <span className="text-xl font-semibold tracking-tight">topics.club</span>
          </div>
          <h1 className="mt-4 max-w-xl text-5xl font-semibold leading-[1.02] tracking-tight text-white sm:text-6xl">
            Community chat
          </h1>
          <p className="mt-5 text-sm font-semibold uppercase tracking-[0.2em] text-cyan-300">IRC, made easy</p>
          <div className="mt-8 flex flex-wrap gap-3">
            <a className="rounded-md bg-white px-4 py-2.5 text-sm font-semibold text-slate-950 transition hover:bg-cyan-100" href="/chat">
              Open chat
            </a>
          </div>
        </div>
        <section aria-label="Suggested topics" className="self-center">
          <div className="mb-3 flex items-end justify-between gap-4">
            <div>
              <h2 className="text-sm font-semibold uppercase tracking-[0.2em] text-slate-500">Start here</h2>
            </div>
          </div>
          <TopicGrid topics={topics} onSelectTopic={onSelectTopic} />
        </section>
      </section>
      {selectedTopic && (
        <AuthPrompt
          developerOauth={developerOauth}
          topic={selectedTopic}
          onClose={onCloseAuth}
        />
      )}
    </main>
  )
}

function AppShell(props) {
  const [mobileMenuOpen, setMobileMenuOpen] = useState(false)
  const [mobileUsersOpen, setMobileUsersOpen] = useState(false)
  const showsUserSidebar = props.view === "chat"

  return (
    <main className="min-h-screen overflow-hidden bg-[#0a0d12] text-slate-100">
      <div
        className={[
          "grid h-screen grid-cols-1",
          showsUserSidebar
            ? "lg:grid-cols-[260px_minmax(0,1fr)_220px]"
            : "lg:grid-cols-[260px_minmax(0,1fr)]",
        ].join(" ")}
      >
        <LeftSidebar {...props} />
        <section className="flex min-h-0 min-w-0 flex-col">
          <TopBar
            {...props}
            showsUserSidebar={showsUserSidebar}
            onOpenMobileMenu={() => setMobileMenuOpen(true)}
            onOpenMobileUsers={() => setMobileUsersOpen(true)}
          />
          {props.view === "discover" ? (
            <DiscoverPane topics={props.topics} onSelectTopic={props.onSelectTopic} />
          ) : props.view === "server" ? (
            <ServerBufferPane
              draft={props.draft}
              messages={props.serverMessages}
              onLoadOlderMessages={props.onLoadOlderMessages}
              onReadingStateChange={props.onReadingStateChange}
              onReconnectServer={props.onReconnectServer}
              server={props.activeServer}
              onSendMessage={props.onSendMessage}
              onUpdateDraft={props.onUpdateDraft}
            />
          ) : (
            <ChatPane {...props} />
          )}
        </section>
        {showsUserSidebar && <RightSidebar activeChannel={props.activeChannel} users={props.users} />}
      </div>
      {mobileMenuOpen && (
        <MobileDrawer side="left" onClose={() => setMobileMenuOpen(false)}>
          <MobileDrawerHeader title="Channels" onClose={() => setMobileMenuOpen(false)} />
          <LeftSidebar
            {...props}
            mobile
            onDiscover={() => {
              props.onDiscover()
              setMobileMenuOpen(false)
            }}
            onSelectChannel={(channel) => {
              props.onSelectChannel(channel)
              setMobileMenuOpen(false)
            }}
            onSelectServer={(server) => {
              props.onSelectServer(server)
              setMobileMenuOpen(false)
            }}
          />
        </MobileDrawer>
      )}
      {showsUserSidebar && mobileUsersOpen && (
        <MobileDrawer side="right" onClose={() => setMobileUsersOpen(false)}>
          <MobileDrawerHeader title="People" onClose={() => setMobileUsersOpen(false)} />
          <RightSidebar activeChannel={props.activeChannel} users={props.users} mobile />
        </MobileDrawer>
      )}
    </main>
  )
}

function MobileDrawer({children, onClose, side}) {
  return (
    <div className="fixed inset-0 z-50 lg:hidden">
      <button className="absolute inset-0 bg-black/70" onClick={onClose} aria-label="Close sidebar" />
      <div className={["absolute top-0 flex h-full w-[min(20rem,88vw)] flex-col bg-[#0f131b] shadow-2xl", side === "right" ? "right-0" : "left-0"].join(" ")}>
        {children}
      </div>
    </div>
  )
}

function MobileDrawerHeader({title, onClose}) {
  return (
    <div className="flex h-14 shrink-0 items-center justify-between border-b border-slate-800/80 px-4">
      <div className="text-sm font-semibold uppercase tracking-[0.16em] text-slate-400">{title}</div>
      <button
        className="grid size-9 place-items-center rounded-md border border-slate-700 text-slate-300 transition hover:border-cyan-300 hover:text-white"
        onClick={onClose}
        aria-label="Close sidebar"
      >
        <span className="hero-x-mark size-5" aria-hidden="true" />
      </button>
    </div>
  )
}

function LeftSidebar({activeChannel, activeServer, connections, currentUser, mobile = false, view, onDiscover, onDisconnectServer, onJoinManualServer, onLeaveChannel, onLeaveServer, onMarkChannelRead, onReconnectServer, onSelectChannel, onSelectServer, onShowChat, onUpdateServer}) {
  const [manualOpen, setManualOpen] = useState(false)
  const [editingServer, setEditingServer] = useState(null)
  const [leavingServer, setLeavingServer] = useState(null)

  return (
    <aside className={[
      "min-h-0 border-r border-slate-800/80 bg-[#0f131b]",
      mobile ? "flex min-h-0 flex-1 flex-col border-r-0" : "hidden lg:flex lg:flex-col",
    ].join(" ")}>
      <div className="flex h-14 items-center justify-between border-b border-slate-800/80 px-4">
        <button className="flex items-center gap-2 text-left" onClick={onShowChat}>
          <AppMark small />
          <span className="font-semibold tracking-tight">topics.club</span>
        </button>
        <button
          id="add-server-button"
          className="grid size-8 place-items-center rounded-md border border-slate-700 text-slate-300 transition hover:border-cyan-300 hover:text-white"
          onClick={() => setManualOpen(true)}
          aria-label="Join another server"
        >
          <span className="hero-plus size-4" aria-hidden="true" />
        </button>
      </div>
      <div className="space-y-2 border-b border-slate-800/80 p-3">
        <button
          id="discover-topics-button"
          className="flex w-full items-center justify-between rounded-md border border-slate-700/80 bg-slate-900/70 px-3 py-2 text-left text-sm text-slate-200 transition hover:border-cyan-300"
          onClick={onDiscover}
        >
          <span>Discover</span>
          <span className="hero-magnifying-glass size-4 text-slate-500" aria-hidden="true" />
        </button>
      </div>
      <nav className="min-h-0 flex-1 overflow-y-auto px-3 py-3" aria-label="Joined topics">
        {connections.map((connection) => (
          <section key={connection.id} className="mb-5">
            <div
              className={[
                "mb-2 flex w-full items-center gap-1 rounded-md pr-1 text-xs font-semibold uppercase tracking-[0.16em] transition",
                activeServer?.id === connection.id && view === "server"
                  ? "bg-slate-800 text-cyan-200"
                  : "text-slate-500 hover:bg-slate-800/70 hover:text-slate-300",
              ].join(" ")}
            >
              <button className="flex min-w-0 flex-1 items-center gap-2 px-1 py-1 text-left" onClick={() => onSelectServer(connection)}>
                <span className="size-1.5 rounded-full bg-emerald-400" />
                <span className="truncate">{connection.name}</span>
              </button>
              <ServerActionMenu
                server={connection}
                onDisconnect={() => onDisconnectServer?.(connection)}
                onEdit={() => setEditingServer(connection)}
                onLeave={() => setLeavingServer(connection)}
                onReconnect={() => onReconnectServer?.(connection)}
              />
            </div>
            <div className="space-y-1">
              {connection.channels.map((channel) => (
                <div
                  key={channel.id}
                  className={[
                    "group flex w-full items-center gap-1 rounded-md border pr-1 text-sm outline-none transition focus-within:border-cyan-300/50",
                    activeChannel?.id === channel.id
                      ? "border border-cyan-300/30 bg-cyan-300/10 text-cyan-100"
                      : "border-transparent text-slate-300 hover:bg-slate-800/80 hover:text-white",
                  ].join(" ")}
                >
                  <button
                    className="flex min-w-0 flex-1 items-center gap-2 px-2 py-2 text-left"
                    onClick={() => onSelectChannel(channel)}
                  >
                    <span className="min-w-0 flex-1 truncate">{channel.channel}</span>
                    {channel.mention_count > 0 && (
                      <span className="rounded-full bg-rose-400 px-1.5 text-xs font-semibold text-slate-950">{channel.mention_count}</span>
                    )}
                  </button>
                  <ChannelActionMenu
                    channel={channel}
                    onCopyChannel={() => navigator.clipboard?.writeText(channel.channel)}
                    onLeaveChannel={() => onLeaveChannel?.(channel)}
                    onMarkRead={() => onMarkChannelRead?.(channel)}
                  />
                </div>
              ))}
            </div>
          </section>
        ))}
      </nav>
      <div className="border-t border-slate-800/80 p-3">
        <div className="flex items-center gap-3 rounded-md bg-slate-900/70 p-2">
          <div className="grid size-9 place-items-center rounded-md bg-emerald-300 text-sm font-bold text-slate-950">
            {currentUser.email.slice(0, 2).toUpperCase()}
          </div>
          <div className="min-w-0">
            <div className="truncate text-sm font-medium">{currentUser.email.split("@")[0]}</div>
            <div className="text-xs text-emerald-300">connected</div>
          </div>
        </div>
      </div>
      {manualOpen && (
        <ManualJoinDialog
          onClose={() => setManualOpen(false)}
          onJoin={(form) => {
            onJoinManualServer(form)
            setManualOpen(false)
          }}
        />
      )}
      {editingServer && (
        <EditServerDialog
          server={editingServer}
          onClose={() => setEditingServer(null)}
          onSave={(form) => {
            onUpdateServer?.(editingServer, form)
            setEditingServer(null)
          }}
        />
      )}
      {leavingServer && (
        <LeaveServerDialog
          server={leavingServer}
          onClose={() => setLeavingServer(null)}
          onConfirm={() => {
            onLeaveServer?.(leavingServer)
            setLeavingServer(null)
          }}
        />
      )}
    </aside>
  )
}

function ChannelActionMenu({channel, onCopyChannel, onLeaveChannel, onMarkRead}) {
  const [open, setOpen] = useState(false)
  const {refs, floatingStyles} = useFloating({
    placement: "bottom-end",
    middleware: [offset(6), shift({padding: 8})],
  })

  function run(action) {
    action?.()
    setOpen(false)
  }

  return (
    <div className="relative">
      <button
        ref={refs.setReference}
        className="grid size-7 place-items-center rounded-md text-slate-500 transition hover:bg-slate-700 hover:text-white"
        aria-label={`Channel actions for ${channel.channel}`}
        aria-expanded={open}
        onClick={(event) => {
          event.stopPropagation()
          setOpen((current) => !current)
        }}
        type="button"
      >
        <span className="hero-ellipsis-horizontal size-4" aria-hidden="true" />
      </button>
      {open && (
        <div
          ref={refs.setFloating}
          style={floatingStyles}
          role="menu"
          aria-label={`${channel.channel} actions`}
          className="z-40 min-w-44 rounded-lg border border-slate-700 bg-[#121722] p-1 text-sm shadow-2xl shadow-black/40"
        >
          <button className="w-full rounded-md px-3 py-2 text-left text-slate-200 transition hover:bg-slate-800" onClick={() => run(onMarkRead)} role="menuitem" type="button">
            Mark read
          </button>
          <button className="w-full rounded-md px-3 py-2 text-left text-slate-200 transition hover:bg-slate-800" onClick={() => run(onCopyChannel)} role="menuitem" type="button">
            Copy channel name
          </button>
          <button className="w-full rounded-md px-3 py-2 text-left text-rose-200 transition hover:bg-rose-950/50" onClick={() => run(onLeaveChannel)} role="menuitem" type="button">
            Leave channel
          </button>
        </div>
      )}
    </div>
  )
}

function ServerActionMenu({server, onDisconnect, onEdit, onLeave, onReconnect}) {
  const [open, setOpen] = useState(false)
  const {refs, floatingStyles} = useFloating({
    placement: "bottom-end",
    middleware: [offset(6), shift({padding: 8})],
  })

  function run(action) {
    action?.()
    setOpen(false)
  }

  return (
    <div className="relative">
      <button
        ref={refs.setReference}
        className="grid size-6 place-items-center rounded-md text-slate-500 transition hover:bg-slate-700 hover:text-white"
        aria-label={`Server actions for ${server.name}`}
        aria-expanded={open}
        onClick={(event) => {
          event.stopPropagation()
          setOpen((current) => !current)
        }}
        type="button"
      >
        <span className="hero-ellipsis-horizontal size-4" aria-hidden="true" />
      </button>
      {open && (
        <div
          ref={refs.setFloating}
          style={floatingStyles}
          role="menu"
          aria-label={`${server.name} actions`}
          className="z-40 min-w-44 rounded-lg border border-slate-700 bg-[#121722] p-1 text-sm normal-case tracking-normal shadow-2xl shadow-black/40"
        >
          <button className="w-full rounded-md px-3 py-2 text-left text-slate-200 transition hover:bg-slate-800" onClick={() => run(onReconnect)} role="menuitem" type="button">
            Connect or reconnect
          </button>
          <button className="w-full rounded-md px-3 py-2 text-left text-slate-200 transition hover:bg-slate-800" onClick={() => run(onEdit)} role="menuitem" type="button">
            Edit connection
          </button>
          <button className="w-full rounded-md px-3 py-2 text-left text-rose-200 transition hover:bg-rose-950/50" onClick={() => run(onDisconnect)} role="menuitem" type="button">
            Disconnect
          </button>
          <button className="w-full rounded-md px-3 py-2 text-left text-rose-200 transition hover:bg-rose-950/50" onClick={() => run(onLeave)} role="menuitem" type="button">
            Leave server
          </button>
        </div>
      )}
    </div>
  )
}

function TopBar({activeChannel, activeServer, connectionHealth, notificationState, showsUserSidebar, view, onOpenMobileMenu, onOpenMobileUsers, onRequestNotifications}) {
  const topBarCopy = topBarCopyFor({activeChannel, activeServer, view})

  return (
    <header className="flex h-14 items-center justify-between border-b border-slate-800/80 bg-[#0d1118] px-4">
      <div className="flex min-w-0 items-center gap-3">
        <button
          className="grid size-9 place-items-center rounded-md border border-slate-700 text-slate-300 transition hover:border-cyan-300 hover:text-white lg:hidden"
          onClick={onOpenMobileMenu}
          aria-label="Show channels"
        >
          <span className="hero-bars-3 size-5" aria-hidden="true" />
        </button>
        <div className="min-w-0">
          <div className="flex items-baseline gap-2">
          <h1 className="truncate text-base font-semibold">{topBarCopy.title}</h1>
          {view !== "server" && (
            topBarCopy.context && <span className="hidden text-xs text-slate-500 sm:inline">{topBarCopy.context}</span>
          )}
          </div>
          <p className="truncate text-xs text-slate-500">{topBarCopy.subtitle}</p>
        </div>
      </div>
      <div className="flex items-center gap-2">
        <ConnectionHealthIndicator status={connectionHealth} />
        {showsUserSidebar && (
          <button
            className="grid size-9 place-items-center rounded-md border border-slate-700 text-slate-300 transition hover:border-cyan-300 hover:text-white lg:hidden"
            onClick={onOpenMobileUsers}
            aria-label="Show users"
          >
            <span className="hero-users size-5" aria-hidden="true" />
          </button>
        )}
        <Tooltip label={notificationLabel(notificationState)}>
          <button
            id="notification-bell"
            className={[
              "grid size-9 place-items-center rounded-md border transition",
              notificationState === "granted"
                ? "border-emerald-400 bg-emerald-400/10 text-emerald-200"
                : "border-slate-700 text-slate-300 hover:border-cyan-300 hover:text-white",
            ].join(" ")}
            onClick={onRequestNotifications}
            aria-label="Enable browser notifications"
          >
            <span className="hero-bell size-4" aria-hidden="true" />
          </button>
        </Tooltip>
      </div>
    </header>
  )
}

function ConnectionHealthIndicator({status}) {
  const labels = {
    connected: "connected",
    degraded: "degraded",
    disconnected: "offline",
    reconnecting: "reconnecting",
  }
  const label = labels[status] || "offline"

  return (
    <div
      className="hidden items-center gap-1.5 rounded-md border border-slate-800 px-2 py-1 text-xs text-slate-400 sm:flex"
      aria-label={`Connection ${label}`}
    >
      <span
        className={[
          "size-1.5 rounded-full",
          status === "connected"
            ? "bg-emerald-300"
            : status === "degraded" || status === "reconnecting"
              ? "bg-amber-300"
              : "bg-slate-500",
        ].join(" ")}
      />
      <span>{label}</span>
    </div>
  )
}

function topBarCopyFor({activeChannel, activeServer, view}) {
  if (view === "discover") {
    return {
      title: "Discover",
      context: null,
      subtitle: "Find more topics to join.",
    }
  }

  if (view === "server") {
    return {
      title: activeServer?.host || "Server",
      context: null,
      subtitle: "Server notices, services, and connection details.",
    }
  }

  return {
    title: activeChannel?.channel || "#elixir",
    context: `on ${activeChannel?.connection?.host || "127.0.0.1"}`,
    subtitle: activeChannel?.topic || "Pick a topic from the sidebar or discover view.",
  }
}

function ChatPane({activeChannel, connectionHealth, draft, messages, onLoadOlderMessages, onReadingStateChange, onRetryMessage, onSendMessage, onUpdateDraft}) {
  const {newMessageCount, readingOlder, scrollRef, scrollToBottom} = useChatScroll(messages, {
    onNearTop: () => onLoadOlderMessages?.(activeChannel?.id),
    onReadingStateChange: (nextReadingOlder) => onReadingStateChange?.(activeChannel?.id, nextReadingOlder),
  })
  const visibleMessages = visibleTimelineMessages(messages, readingOlder)
  const sendDisabled = isRealtimeChannel(activeChannel) && connectionHealth !== "connected"

  return (
    <section className="flex min-h-0 flex-1 flex-col bg-[#090b10]">
      <div id="chat-scrollback" ref={scrollRef} className="min-h-0 flex-1 overflow-y-auto px-3 py-4 sm:px-6">
        <div className="mx-auto max-w-4xl space-y-1">
          <MessageTimeline messages={visibleMessages} onRetryMessage={onRetryMessage} />
        </div>
      </div>
      {newMessageCount > 0 && <NewMessagesButton count={newMessageCount} onClick={scrollToBottom} />}
      <ChatComposer
        inputId="chat-message-input"
        draft={draft}
        disabled={sendDisabled}
        onSendMessage={onSendMessage}
        onUpdateDraft={onUpdateDraft}
        placeholder={activeChannel ? "Write a message" : "Choose a topic first"}
      />
    </section>
  )
}

function NewMessagesButton({count, onClick}) {
  return (
    <div className="pointer-events-none -mt-12 flex justify-center">
      <button
        className="pointer-events-auto rounded-full border border-cyan-300/40 bg-cyan-300 px-3 py-1.5 text-xs font-semibold text-slate-950 shadow-lg shadow-black/30 transition hover:bg-white"
        onClick={onClick}
        type="button"
      >
        {count} new {count === 1 ? "message" : "messages"}
      </button>
    </div>
  )
}

function MessageTimeline({messages, onRetryMessage}) {
  return (
    <>
      {messages.map((message, index) => {
        const previous = messages[index - 1]
        const showSeparator = !previous || minutesBetween(previous.occurredAt, message.occurredAt) >= 30

        return (
          <React.Fragment key={message.id}>
            {showSeparator && <TimeSeparator value={message.occurredAt} />}
            <MessageRow message={message} onRetryMessage={onRetryMessage} />
          </React.Fragment>
        )
      })}
    </>
  )
}

function TimeSeparator({value}) {
  return (
    <div className="my-4 flex items-center justify-center gap-3 text-xs text-slate-600">
      <span className="h-px flex-1 bg-slate-800/80" />
      <time dateTime={value}>{formatTimestamp(value)}</time>
      <span className="h-px flex-1 bg-slate-800/80" />
    </div>
  )
}

function MessageRow({message, onRetryMessage}) {
  if (message.kind === "system") {
    return <div className="px-2 py-1 text-xs italic text-emerald-300">{message.body}</div>
  }

  return (
    <div className="group relative rounded-md px-2 py-1.5 text-sm leading-6 hover:bg-slate-900/70">
      <span className="font-semibold text-amber-200">{message.nick}</span>
      <span className="text-slate-500">: </span>
      <span className="break-words text-slate-200">{message.body}</span>
      {message.pending && <span className="ml-2 text-xs text-slate-500">sending</span>}
      {message.failed && (
        <button
          className="ml-2 rounded border border-rose-400/40 px-1.5 py-0.5 text-xs font-semibold text-rose-200 transition hover:border-rose-200 hover:text-white"
          onClick={() => onRetryMessage?.(message)}
          type="button"
        >
          Retry
        </button>
      )}
      <time
        className="pointer-events-none absolute right-2 top-1.5 rounded bg-slate-950/90 px-1.5 text-xs text-slate-500 opacity-0 transition-opacity group-hover:opacity-100 group-focus-within:opacity-100"
        dateTime={message.occurredAt}
      >
        {formatTime(message.occurredAt)}
      </time>
    </div>
  )
}

function DiscoverPane({topics, onSelectTopic}) {
  return (
    <section className="min-h-0 flex-1 overflow-y-auto bg-[#090b10] p-4 sm:p-6">
      <div className="mx-auto max-w-5xl">
        <div className="mb-5 flex flex-wrap items-end justify-between gap-3">
          <div>
            <h2 className="text-2xl font-semibold tracking-tight">Discover topics</h2>
            <p className="mt-1 text-sm text-slate-500">Join a suggested conversation or add your own server from the sidebar.</p>
          </div>
        </div>
        <TopicGrid topics={topics} onSelectTopic={onSelectTopic} />
      </div>
    </section>
  )
}

function ServerBufferPane({draft, messages, onLoadOlderMessages, onReadingStateChange, onReconnectServer, server, onSendMessage, onUpdateDraft}) {
  const {newMessageCount, readingOlder, scrollRef, scrollToBottom} = useChatScroll(messages, {
    onNearTop: () => onLoadOlderMessages?.(server?.id),
    onReadingStateChange: (nextReadingOlder) => onReadingStateChange?.(server?.id, nextReadingOlder),
  })
  const visibleMessages = visibleTimelineMessages(messages, readingOlder)

  if (!server) return null

  return (
    <section className="flex min-h-0 flex-1 flex-col bg-[#090b10]">
      <div id="server-scrollback" ref={scrollRef} className="min-h-0 flex-1 overflow-y-auto px-3 py-4 sm:px-6">
        <div className="mx-auto max-w-4xl">
          <div className="mb-4 rounded-lg border border-slate-800 bg-[#121722] p-4">
            <div className="text-xs font-semibold uppercase tracking-[0.18em] text-slate-500">Server buffer</div>
            <h2 className="mt-2 text-xl font-semibold tracking-tight">{server.host}</h2>
            <p className="mt-2 text-sm leading-6 text-slate-500">
              Notices, connection logs, service replies, and server-level commands live here.
            </p>
          </div>
          <ServerStatusBanner server={server} onReconnectServer={onReconnectServer} />
          <MessageTimeline messages={visibleMessages} />
        </div>
      </div>
      {newMessageCount > 0 && <NewMessagesButton count={newMessageCount} onClick={scrollToBottom} />}
      <ChatComposer
        inputId="server-command-input"
        draft={draft}
        disabled={false}
        onSendMessage={onSendMessage}
        onUpdateDraft={onUpdateDraft}
        placeholder="Message a service or type a server command"
      />
    </section>
  )
}

function ServerStatusBanner({onReconnectServer, server}) {
  if (!server || server.status === "connected") return null

  const label = server.status === "errored" ? "Server error" : `Server ${server.status || "offline"}`
  const canReconnect = server.status !== "connecting" && server.status !== "reconnecting"

  return (
    <div
      className="mb-4 flex flex-wrap items-center justify-between gap-3 rounded-md border border-amber-300/25 bg-amber-300/10 px-3 py-2 text-sm text-amber-100"
      role="status"
    >
      <div>
        <div className="font-semibold">{label}</div>
        <div className="text-xs text-amber-100/70">IRC messages for this server may be delayed until it reconnects.</div>
      </div>
      {canReconnect && (
        <button
          className="rounded-md border border-amber-200/40 px-3 py-1.5 text-xs font-semibold text-amber-50 transition hover:border-amber-100 hover:bg-amber-100 hover:text-slate-950"
          onClick={() => onReconnectServer?.(server)}
          type="button"
        >
          Reconnect
        </button>
      )}
    </div>
  )
}

function ChatComposer({disabled = false, draft, inputId, onSendMessage, onUpdateDraft, placeholder}) {
  const suggestions = commandSuggestionsFor(draft)
  const {refs, floatingStyles} = useFloating({
    placement: "top-start",
    middleware: [offset(8), shift({padding: 12})],
  })

  return (
    <form className="relative border-t border-slate-800/80 bg-[#0f131b] p-3 sm:p-4" onSubmit={onSendMessage}>
      {suggestions.length > 0 && (
        <div
          ref={refs.setFloating}
          style={floatingStyles}
          role="listbox"
          aria-label="Slash command suggestions"
          className="z-30 w-[min(28rem,calc(100vw-2rem))] overflow-hidden rounded-lg border border-slate-700 bg-[#121722] p-1 shadow-2xl shadow-black/40"
        >
          {suggestions.map((command) => (
            <button
              key={command.name}
              type="button"
              role="option"
              aria-selected="false"
              className="grid w-full grid-cols-[4.5rem_1fr] gap-3 rounded-md px-3 py-2 text-left text-sm transition hover:bg-slate-800/80"
              onMouseDown={(event) => {
                event.preventDefault()
                onUpdateDraft(`${command.name} `)
              }}
            >
              <span className="font-semibold text-cyan-200">{command.name}</span>
              <span className="min-w-0">
                <span className="block truncate text-slate-300">{command.description}</span>
                <span className="block truncate text-xs text-slate-500">{command.usage}</span>
              </span>
            </button>
          ))}
        </div>
      )}
      <div
        ref={refs.setReference}
        className="mx-auto flex max-w-4xl items-center gap-2 rounded-md border border-slate-700 bg-slate-950 px-3 transition focus-within:border-cyan-300"
      >
        <input
          id={inputId}
          aria-label="Message composer"
          className="min-w-0 flex-1 bg-transparent py-3 text-sm text-slate-100 outline-none placeholder:text-slate-600"
          value={draft}
          onChange={(event) => onUpdateDraft(event.target.value)}
          placeholder={placeholder}
        />
        <button
          className="rounded-md bg-cyan-300 px-3 py-1.5 text-sm font-semibold text-slate-950 transition hover:bg-white disabled:cursor-not-allowed disabled:bg-slate-700 disabled:text-slate-400"
          disabled={disabled}
        >
          Send
        </button>
      </div>
    </form>
  )
}

function RightSidebar({activeChannel, users, mobile = false}) {
  const [expandedGroups, setExpandedGroups] = useState({})
  const groupedUsers = [
    {label: "Mods", users: users.filter((user) => ["owner", "admin", "op", "halfop"].includes(user.role))},
    {label: "Voiced", users: users.filter((user) => user.role === "voice")},
    {label: "Online", users: users.filter((user) => (!user.role || user.role === "user") && user.status !== "away")},
    {label: "Away", users: users.filter((user) => user.status === "away")},
  ].filter((group) => group.users.length > 0)

  return (
    <aside className={[
      "min-h-0 border-l border-slate-800/80 bg-[#0f131b]",
      mobile ? "block min-h-0 flex-1 border-l-0" : "hidden lg:block",
    ].join(" ")} aria-label="People here">
      <div className="border-b border-slate-800/80 px-4 py-4">
        <h2 className="text-xs font-semibold uppercase tracking-[0.18em] text-slate-500">People here</h2>
        <p className="mt-1 text-sm text-slate-300">{activeChannel?.channel || "#elixir"}</p>
      </div>
      <div className="max-h-[calc(100vh-5.5rem)] space-y-4 overflow-y-auto p-3">
        {groupedUsers.map((group) => (
          <section key={group.label}>
            <div className="mb-1 flex items-center justify-between px-2 text-[0.65rem] font-semibold uppercase tracking-[0.16em] text-slate-600">
              <span>{group.label}</span>
              <span>{group.users.length}</span>
            </div>
            <div className="space-y-1">
              {(expandedGroups[group.label] ? group.users : group.users.slice(0, 10)).map((user) => (
                <UserListItem key={user.nick} user={user} />
              ))}
              {!expandedGroups[group.label] && group.users.length > 10 && (
                <button
                  className="w-full rounded-md px-2 py-1.5 text-left text-xs font-semibold text-cyan-200 transition hover:bg-slate-800/70 hover:text-white"
                  onClick={() => setExpandedGroups((current) => ({...current, [group.label]: true}))}
                >
                  +{group.users.length - 10} more
                </button>
              )}
            </div>
          </section>
        ))}
      </div>
    </aside>
  )
}

function UserListItem({user}) {
  const role = ["owner", "admin", "op", "halfop"].includes(user.role) ? "mod" : user.role === "voice" ? "voice" : "user"

  return (
    <div className="flex items-center gap-2 rounded-md px-2 py-1.5 text-sm text-slate-300 hover:bg-slate-800/70">
      <span className={["size-2 rounded-full", user.status === "away" ? "bg-amber-300" : "bg-emerald-300"].join(" ")} />
      <span className="min-w-0 flex-1 truncate">{user.nick}</span>
      <span
        className={[
          "rounded px-1.5 py-0.5 text-[0.65rem] font-semibold uppercase tracking-wide",
          role === "mod"
            ? "bg-cyan-300/15 text-cyan-200"
            : role === "voice"
              ? "bg-violet-300/15 text-violet-200"
              : "bg-slate-800 text-slate-500",
        ].join(" ")}
      >
        {role}
      </span>
    </div>
  )
}

export function TopicGrid({topics, onSelectTopic}) {
  return (
    <div className="grid gap-3 sm:grid-cols-2">
      {topics.map((topic) => {
        const normalized = normalizeTopic(topic)

        return (
          <button
            key={normalized.id}
            className="group rounded-lg border border-slate-800 bg-[#121722] p-3 text-left transition hover:-translate-y-0.5 hover:border-cyan-300 hover:bg-[#161d2a]"
            onClick={() => onSelectTopic(normalized)}
          >
            <div className="min-w-0">
              <div className="min-w-0 flex-1">
                <div className="break-words text-lg font-semibold tracking-tight text-white">{normalized.channel}</div>
                <div className="mt-0.5 truncate text-xs text-slate-500">on {normalized.server_host}</div>
              </div>
            </div>
            <p className="mt-3 min-h-10 text-sm leading-5 text-slate-400">{normalized.description}</p>
            <div className="mt-3 flex items-center justify-between text-xs text-slate-500">
              <span>{normalized.members || "many"} online</span>
              <span className="font-semibold text-cyan-200 transition group-hover:text-white">Join</span>
            </div>
          </button>
        )
      })}
    </div>
  )
}

function AuthPrompt({developerOauth, topic, onClose}) {
  const topicParam = encodeURIComponent(topic.id)

  return (
    <div className="fixed inset-0 z-50 grid place-items-center bg-black/70 px-4">
      <section
        aria-label="Sign in to join"
        className="w-full max-w-md rounded-lg border border-slate-700 bg-[#101620] p-5 shadow-2xl"
        role="dialog"
      >
        <div className="flex items-start justify-between gap-4">
          <div>
            <h2 className="text-lg font-semibold">Sign in to join</h2>
            <p className="mt-1 text-sm text-slate-400">
              {topic.channel}
              <span className="block text-xs text-slate-500">on {topic.server_host}</span>
            </p>
          </div>
          <button className="rounded-md px-2 py-1 text-slate-500 hover:bg-slate-800 hover:text-white" onClick={onClose} aria-label="Close">
            x
          </button>
        </div>
        <div className="mt-5 space-y-3">
          <a className="block rounded-md bg-white px-4 py-2.5 text-center text-sm font-semibold text-slate-950 hover:bg-cyan-100" href={`/auth/google?topic=${topicParam}`}>
            Continue with Google
          </a>
          {developerOauth && (
            <a className="block rounded-md border border-slate-700 px-4 py-2.5 text-center text-sm font-semibold text-slate-200 hover:border-cyan-300" href={`/auth/developer?topic=${topicParam}`}>
              Developer OAuth
            </a>
          )}
        </div>
      </section>
    </div>
  )
}

function ManualJoinDialog({onClose, onJoin}) {
  const [form, setForm] = useState({host: "127.0.0.1", port: "6667", channels: "#elixir, #phoenix", useTls: false})

  function submit(event) {
    event.preventDefault()
    onJoin(form)
  }

  return (
    <div className="fixed inset-0 z-50 grid place-items-center bg-black/70 px-4">
      <form className="w-full max-w-md rounded-lg border border-slate-700 bg-[#101620] p-5 shadow-2xl" onSubmit={submit}>
        <div className="flex items-start justify-between">
          <div>
            <h2 className="text-lg font-semibold">Join another server</h2>
            <p className="mt-1 text-sm text-slate-500">Specify connection details to connect to a new server.</p>
          </div>
          <button type="button" className="rounded-md px-2 py-1 text-slate-500 hover:bg-slate-800 hover:text-white" onClick={onClose}>
            x
          </button>
        </div>
        <div className="mt-5 space-y-3">
          <LabeledInput id="server-host" label="Server" value={form.host} onChange={(host) => setForm({...form, host})} />
          <div className="grid grid-cols-[1fr_auto] items-end gap-3">
            <LabeledInput id="server-port" label="Port" value={form.port} onChange={(port) => setForm({...form, port})} />
            <label className="flex h-[42px] items-center gap-2 rounded-md border border-slate-800 bg-slate-950 px-3 text-sm text-slate-300">
              <input type="checkbox" checked={form.useTls} onChange={(event) => setForm({...form, useTls: event.target.checked})} />
              <span>TLS</span>
            </label>
          </div>
          <LabeledInput
            id="server-channels"
            label="Auto-join channels"
            value={form.channels}
            onChange={(channels) => setForm({...form, channels})}
          />
          <p className="text-xs leading-5 text-slate-500">Comma separated. These channels are joined after the server connects.</p>
        </div>
        <div className="mt-5 flex gap-3">
          <button type="button" className="flex-1 rounded-md border border-slate-700 px-4 py-2 text-sm font-semibold text-slate-300" onClick={onClose}>
            Cancel
          </button>
          <button className="flex-1 rounded-md bg-cyan-300 px-4 py-2 text-sm font-semibold text-slate-950 hover:bg-white">
            Join
          </button>
        </div>
      </form>
    </div>
  )
}

function EditServerDialog({onClose, onSave, server}) {
  const [form, setForm] = useState({
    host: server.host || "",
    port: String(server.port || 6667),
    nickname: server.nickname || "",
    useTls: Boolean(server.use_tls || server.useTls),
  })

  function submit(event) {
    event.preventDefault()
    onSave(form)
  }

  return (
    <div className="fixed inset-0 z-50 grid place-items-center bg-black/70 px-4">
      <form
        aria-label="Edit server"
        className="w-full max-w-md rounded-lg border border-slate-700 bg-[#101620] p-5 shadow-2xl"
        onSubmit={submit}
        role="dialog"
      >
        <div className="flex items-start justify-between">
          <div>
            <h2 className="text-lg font-semibold">Edit connection</h2>
            <p className="mt-1 text-sm text-slate-500">Update the server details used for this connection.</p>
          </div>
          <button type="button" className="rounded-md px-2 py-1 text-slate-500 hover:bg-slate-800 hover:text-white" onClick={onClose}>
            x
          </button>
        </div>
        <div className="mt-5 space-y-3">
          <LabeledInput id="edit-server-host" label="Server" value={form.host} onChange={(host) => setForm({...form, host})} />
          <div className="grid grid-cols-[1fr_auto] items-end gap-3">
            <LabeledInput id="edit-server-port" label="Port" value={form.port} onChange={(port) => setForm({...form, port})} />
            <label className="flex h-[42px] items-center gap-2 rounded-md border border-slate-800 bg-slate-950 px-3 text-sm text-slate-300">
              <input type="checkbox" checked={form.useTls} onChange={(event) => setForm({...form, useTls: event.target.checked})} />
              <span>TLS</span>
            </label>
          </div>
          <LabeledInput id="edit-server-nickname" label="Nickname" value={form.nickname} onChange={(nickname) => setForm({...form, nickname})} />
        </div>
        <div className="mt-5 flex gap-3">
          <button type="button" className="flex-1 rounded-md border border-slate-700 px-4 py-2 text-sm font-semibold text-slate-300" onClick={onClose}>
            Cancel
          </button>
          <button className="flex-1 rounded-md bg-cyan-300 px-4 py-2 text-sm font-semibold text-slate-950 hover:bg-white">
            Save
          </button>
        </div>
      </form>
    </div>
  )
}

function LeaveServerDialog({onClose, onConfirm, server}) {
  return (
    <div className="fixed inset-0 z-50 grid place-items-center bg-black/70 px-4">
      <section
        aria-label="Leave server"
        className="w-full max-w-sm rounded-lg border border-rose-900/70 bg-[#101620] p-5 shadow-2xl"
        role="dialog"
      >
        <div className="flex items-start justify-between gap-4">
          <div>
            <h2 className="text-lg font-semibold">Leave server</h2>
            <p className="mt-2 text-sm leading-6 text-slate-400">
              Remove {server.name} and its joined topics from this account.
            </p>
          </div>
          <button type="button" className="rounded-md px-2 py-1 text-slate-500 hover:bg-slate-800 hover:text-white" onClick={onClose}>
            x
          </button>
        </div>
        <div className="mt-5 flex gap-3">
          <button type="button" className="flex-1 rounded-md border border-slate-700 px-4 py-2 text-sm font-semibold text-slate-300" onClick={onClose}>
            Cancel
          </button>
          <button className="flex-1 rounded-md bg-rose-300 px-4 py-2 text-sm font-semibold text-slate-950 hover:bg-white" onClick={onConfirm} type="button">
            Leave
          </button>
        </div>
      </section>
    </div>
  )
}

function LabeledInput({id, label, value, onChange}) {
  return (
    <label className="block text-sm">
      <span className="mb-1 block text-xs font-semibold uppercase tracking-[0.14em] text-slate-500">{label}</span>
      <input
        id={id}
        className="w-full rounded-md border border-slate-800 bg-slate-950 px-3 py-2 text-slate-100 outline-none transition focus:border-cyan-300"
        value={value}
        onChange={(event) => onChange(event.target.value)}
      />
    </label>
  )
}

function Tooltip({children, label}) {
  const [open, setOpen] = useState(false)
  const [arrowEl, setArrowEl] = useState(null)
  const {refs, floatingStyles, context} = useFloating({
    open,
    onOpenChange: setOpen,
    placement: "bottom-end",
    middleware: [offset(8), shift(), arrow({element: arrowEl})],
  })

  return (
    <>
      {React.cloneElement(children, {
        ref: refs.setReference,
        onMouseEnter: () => setOpen(true),
        onMouseLeave: () => setOpen(false),
        onFocus: () => setOpen(true),
        onBlur: () => setOpen(false),
      })}
      {open && (
        <div
          ref={refs.setFloating}
          style={floatingStyles}
          className="z-50 max-w-56 rounded-md border border-slate-700 bg-slate-950 px-3 py-2 text-xs text-slate-200 shadow-xl"
          role="tooltip"
        >
          {label}
          <FloatingArrow ref={setArrowEl} context={context} className="fill-slate-950" />
        </div>
      )}
    </>
  )
}

function AppMark({small = false}) {
  return (
    <span className={["grid place-items-center rounded-md bg-cyan-300 font-black text-slate-950", small ? "size-7 text-xs" : "size-9 text-sm"].join(" ")}>
      #
    </span>
  )
}

function initialConnections() {
  return [
    {
      id: "server-local",
      name: "local",
      host: "127.0.0.1",
      status: "connected",
      channels: [
        {id: "chan-elixir", channel: "#elixir", topic: "Phoenix, OTP, releases, and production Elixir help.", unread_count: 0, mention_count: 1},
        {id: "chan-phoenix", channel: "#phoenix", topic: "LiveView patterns and framework support.", unread_count: 2, mention_count: 0},
      ],
    },
    {
      id: "server-local-testing",
      name: "local testing",
      host: "127.0.0.1",
      status: "connected",
      channels: [
        {id: "chan-linux", channel: "#linux", topic: "Linux systems and troubleshooting.", unread_count: 0, mention_count: 0},
      ],
    },
  ]
}

function seededMessagesFor(topic) {
  return [
    {
      id: `${topic.id}-1`,
      occurredAt: new Date().toISOString(),
      nick: "topics.club",
      body: `Joined ${topic.channel} on ${topic.server_host}.`,
      kind: "system",
    },
    {
      id: `${topic.id}-2`,
      occurredAt: new Date().toISOString(),
      nick: "mira",
      body: `Welcome to ${topic.channel}. This is placeholder chat until the IRC backend is wired.`,
    },
  ]
}

function serverBufferMessages(server) {
  return [
    {
      id: `${server.id}-connected`,
      occurredAt: "2026-05-13T09:30:00Z",
      nick: server.host,
      body: `Connected to ${server.host} using TLS.`,
      kind: "system",
    },
    {
      id: `${server.id}-welcome`,
      occurredAt: "2026-05-13T09:30:01Z",
      nick: server.host,
      body: "Welcome to the network. This is the server buffer for notices and connection logs.",
    },
    {
      id: `${server.id}-nickserv`,
      occurredAt: "2026-05-13T09:30:03Z",
      nick: "NickServ",
      body: "This nickname is registered. Use IDENTIFY if you own it.",
    },
    {
      id: `${server.id}-chanserv`,
      occurredAt: "2026-05-13T09:33:00Z",
      nick: "ChanServ",
      body: "Channel service replies and registration notices can appear here.",
    },
    {
      id: `${server.id}-joined`,
      occurredAt: "2026-05-13T09:35:00Z",
      nick: server.host,
      body: `Joined ${server.channels.map((channel) => channel.channel).join(", ")}.`,
      kind: "system",
    },
  ]
}

function normalizeTopic(topic) {
  return {
    ...topic,
    id: topic.id || `${topic.server_host}-${topic.channel}`,
    channel: normalizeChannel(topic.channel || topic.name),
    name: normalizeChannel(topic.channel || topic.name),
    description: topic.description || "A live topic you can join.",
    members: topic.members || topic.member_count,
    vibe: topic.vibe || "topic",
  }
}

function normalizeMessage(message) {
  return {
    ...message,
    occurredAt: message.occurredAt || message.occurred_at,
  }
}

function isRealtimeChannel(channel) {
  return channel?.id?.startsWith("channel:")
}

export function visibleTimelineMessages(messages, readingOlder, limit = MESSAGE_RENDER_LIMIT) {
  if (readingOlder || messages.length <= limit) return messages
  return messages.slice(-limit)
}

export function trimMessagesToLimit(messages, limit = MESSAGE_RENDER_LIMIT) {
  if (messages.length <= limit) return messages
  return messages.slice(-limit)
}

export function appendTimelineMessage(messages, message, readingOlder, limit = MESSAGE_RENDER_LIMIT) {
  const nextMessages = [...messages, message]
  return readingOlder ? nextMessages : trimMessagesToLimit(nextMessages, limit)
}

function mergeOlderMessages(olderMessages, currentMessages) {
  const currentIds = new Set(currentMessages.map((message) => message.id))
  return [...olderMessages.filter((message) => !currentIds.has(message.id)), ...currentMessages]
}

function applyUserDiff(users, diff) {
  if (!diff) return users

  if (diff.action === "join" && diff.user?.nick) {
    if (users.some((user) => user.nick === diff.user.nick)) return users
    return [...users, diff.user]
  }

  if ((diff.action === "part" || diff.action === "quit") && diff.nick) {
    return users.filter((user) => user.nick !== diff.nick)
  }

  if (diff.action === "nick" && diff.old_nick && diff.new_nick) {
    return users.map((user) => (user.nick === diff.old_nick ? {...user, nick: diff.new_nick} : user))
  }

  if (diff.action === "away" && diff.nick && diff.status) {
    return users.map((user) => (user.nick === diff.nick ? {...user, status: diff.status} : user))
  }

  if (diff.action === "role" && diff.nick && diff.role) {
    return users.map((user) => (user.nick === diff.nick ? {...user, role: diff.role} : user))
  }

  return users
}

function normalizeChannel(channel) {
  if (!channel) return "#general"
  return channel.startsWith("#") ? channel : `#${channel}`
}

function commandSuggestionsFor(value) {
  const trimmedStart = value.trimStart()
  if (!trimmedStart.startsWith("/") || trimmedStart.includes(" ")) return []

  const prefix = trimmedStart.slice(1).toLowerCase()
  return slashCommands.filter((command) => command.name.slice(1).startsWith(prefix))
}

function notificationPermission() {
  if (!("Notification" in window)) return "default"
  return Notification.permission
}

function notificationLabel(state) {
  if (state === "granted") return "Browser notifications are enabled for mentions while this tab is hidden."
  if (state === "denied") return "Notifications are blocked in your browser settings."
  if (state === "unsupported") return "This browser does not support notifications."
  return "Enable browser notifications for mentions."
}

function useChatScroll(messages, {onNearTop, onReadingStateChange} = {}) {
  const scrollRef = React.useRef(null)
  const previousScrollHeightRef = React.useRef(0)
  const previousLastMessageIdRef = React.useRef(null)
  const previousMessageLengthRef = React.useRef(0)
  const readingOlderRef = React.useRef(false)
  const [readingOlder, setReadingOlder] = useState(false)
  const [newMessageCount, setNewMessageCount] = useState(0)

  useEffect(() => {
    const node = scrollRef.current
    if (!node) return
    const updateReadingState = ({loadOlder = false} = {}) => {
      const distanceFromBottom = node.scrollHeight - node.scrollTop - node.clientHeight
      const nextReadingOlder = distanceFromBottom > 96
      if (readingOlderRef.current !== nextReadingOlder) {
        readingOlderRef.current = nextReadingOlder
        setReadingOlder(nextReadingOlder)
        onReadingStateChange?.(nextReadingOlder)
      }
      if (!nextReadingOlder) setNewMessageCount(0)
      if (loadOlder && node.scrollTop <= 80 && node.scrollHeight > node.clientHeight) onNearTop?.()
    }

    updateReadingState()
    const handleScroll = () => updateReadingState({loadOlder: true})
    node.addEventListener("scroll", handleScroll)

    return () => node.removeEventListener("scroll", handleScroll)
  }, [onNearTop, onReadingStateChange])

  useEffect(() => {
    const node = scrollRef.current
    if (!node || readingOlder) return
    node.scrollTop = node.scrollHeight
  }, [messages.length, readingOlder])

  useEffect(() => {
    const node = scrollRef.current
    if (!node || !readingOlder) return

    const previousScrollHeight = previousScrollHeightRef.current
    if (previousScrollHeight > 0 && node.scrollHeight > previousScrollHeight) {
      node.scrollTop += node.scrollHeight - previousScrollHeight
    }

    previousScrollHeightRef.current = node.scrollHeight
  }, [messages.length, readingOlder])

  useEffect(() => {
    const lastMessage = messages[messages.length - 1]
    const previousLastMessageId = previousLastMessageIdRef.current
    const previousLength = previousMessageLengthRef.current

    if (
      readingOlderRef.current &&
      previousLastMessageId != null &&
      lastMessage?.id !== previousLastMessageId &&
      messages.length > previousLength
    ) {
      setNewMessageCount((current) => current + messages.length - previousLength)
    }

    previousLastMessageIdRef.current = lastMessage?.id ?? null
    previousMessageLengthRef.current = messages.length
  }, [messages])

  function scrollToBottom() {
    const node = scrollRef.current
    if (node) node.scrollTop = node.scrollHeight
    readingOlderRef.current = false
    setReadingOlder(false)
    onReadingStateChange?.(false)
    setNewMessageCount(0)
  }

  return {newMessageCount, readingOlder, scrollRef, scrollToBottom}
}

function minutesBetween(previous, current) {
  return Math.abs(new Date(current).getTime() - new Date(previous).getTime()) / 60_000
}

function formatTimestamp(value) {
  return new Intl.DateTimeFormat([], {
    month: "short",
    day: "numeric",
    hour: "numeric",
    minute: "2-digit",
  }).format(new Date(value))
}

function formatTime(value) {
  return new Intl.DateTimeFormat([], {hour: "numeric", minute: "2-digit"}).format(new Date(value))
}
