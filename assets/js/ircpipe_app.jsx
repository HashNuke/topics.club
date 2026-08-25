import React, {useEffect, useMemo, useRef, useState} from "react"
import {FloatingArrow, arrow, offset, shift, useFloating} from "@floating-ui/react"
import {createApiClient} from "./api_client.js"
import AppMark from "./components/app_mark.jsx"
import ChatPane, {
  NewMessagesButton,
  composerStatusLabel,
  isRealtimeChannel,
  realtimeReadyFor,
  useChatScroll,
  visibleTimelineMessages,
} from "./components/chat_pane.jsx"
import ChatComposer from "./components/chat_composer.jsx"
import MessageTimeline from "./components/message_timeline.jsx"
import {
  applyUserDiff,
  appendTimelineMessage,
  mergeNewerMessages,
  mergeOlderMessages,
  normalizeChannel,
  normalizeMessage,
  normalizeTopic,
  trimMessagesToLimit,
} from "./chat_store.js"
export {appendTimelineMessage, trimMessagesToLimit} from "./chat_store.js"
export {MESSAGE_RENDER_LIMIT, visibleTimelineMessages} from "./components/chat_pane.jsx"

const csrfToken = document.querySelector("meta[name='csrf-token']")?.getAttribute("content")

export const demoTopics = [
  {
    id: "local-elixir",
    name: "#elixir",
    description: "Phoenix, OTP, releases, and production Elixir help.",
    server_host: "127.0.0.1",
    server_port: 6669,
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
    server_port: 6669,
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
    server_port: 6669,
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
    server_port: 6669,
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
    server_port: 6669,
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
    server_port: 6669,
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

const demoSlashCommands = [
  {name: "/join", usage: "/join #channel", description: "Join a channel"},
  {name: "/list", usage: "/list", description: "Browse channels on this server"},
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
  const [topics, setTopics] = useState([])
  const [topicsLoaded, setTopicsLoaded] = useState(false)
  const [authTopic, setAuthTopic] = useState(null)
  const [view, setView] = useState("chat")
  const [notificationState, setNotificationState] = useState(notificationPermission())
  const [connectionHealth, setConnectionHealth] = useState("disconnected")
  const [connections, setConnections] = useState(() => (currentUser ? [] : initialConnections()))
  const [activeChannelId, setActiveChannelId] = useState(() => (currentUser ? null : "chan-elixir"))
  const [activeServerId, setActiveServerId] = useState(() => (currentUser ? null : "server-local"))
  const [messagesByChannel, setMessagesByChannel] = useState(() => (currentUser ? {} : {"chan-elixir": demoMessages}))
  const [messagesByServer, setMessagesByServer] = useState(() =>
    currentUser ? {} : Object.fromEntries(initialConnections().map((connection) => [connection.id, serverBufferMessages(connection)]))
  )
  const [usersByChannel, setUsersByChannel] = useState({})
  const [draft, setDraft] = useState("")
  const [composerError, setComposerError] = useState(null)
  const [commandCatalog, setCommandCatalog] = useState(() => (currentUser ? [] : demoSlashCommands))
  const [channelDirectory, setChannelDirectory] = useState({serverId: null, channels: [], status: "idle", error: null, joinError: null, joiningChannel: null})
  const channelDirectoryRequestRef = useRef(0)
  const loadingOlderRef = useRef(new Set())
  const readingBuffersRef = useRef(new Set())
  const activeChannelIdRef = useRef(activeChannelId)
  const activeServerIdRef = useRef(activeServerId)
  const connectionsRef = useRef(connections)
  const messagesByChannelRef = useRef(messagesByChannel)
  const messagesByServerRef = useRef(messagesByServer)
  const reconcilingBuffersRef = useRef(new Set())
  const rejectedBufferIdsRef = useRef(new Set())
  const joinRejectionVersionsRef = useRef(new Map())
  const realtimeClientRef = useRef(null)
  const notificationStateRef = useRef(notificationState)
  const requestedTopicIdRef = useRef(requestedTopicId())
  const viewRef = useRef(view)

  useEffect(() => {
    connectionsRef.current = connections
  }, [connections])

  useEffect(() => {
    viewRef.current = view
  }, [view])

  useEffect(() => {
    messagesByChannelRef.current = messagesByChannel
  }, [messagesByChannel])

  useEffect(() => {
    messagesByServerRef.current = messagesByServer
  }, [messagesByServer])

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
        setTopics(topics?.length ? topics.map(normalizeTopic) : [])
        setTopicsLoaded(true)
      })
      .catch(() => {
        setTopics([])
        setTopicsLoaded(true)
      })
  }, [apiClient])

  useEffect(() => {
    if (!currentUser || mode === "landing" || !topicsLoaded || !requestedTopicIdRef.current) return

    const requestedTopic = topicForRequestedId(requestedTopicIdRef.current, topics)
    if (!requestedTopic) return

    requestedTopicIdRef.current = null
    joinTopic(requestedTopic)
    if (window.history?.replaceState) window.history.replaceState(null, "", window.location.pathname)
  }, [currentUser?.id, mode, topics, topicsLoaded])

  useEffect(() => {
    if (!currentUser || mode === "landing") return

    apiClient
      .bootstrap()
      .then((bootstrap) => applyBootstrap(bootstrap))
      .catch(() => {})
  }, [apiClient, currentUser?.id, mode])

  useEffect(() => {
    if (!currentUser || mode === "landing" || !apiClient.activity) return

    const touchActivity = () => {
      apiClient.activity().catch(() => {})
    }

    const handleVisibilityChange = () => {
      if (document.visibilityState === "visible") touchActivity()
    }

    touchActivity()
    document.addEventListener("visibilitychange", handleVisibilityChange)
    window.addEventListener("focus", touchActivity)
    const interval = window.setInterval(touchActivity, 30 * 60 * 1000)

    return () => {
      document.removeEventListener("visibilitychange", handleVisibilityChange)
      window.removeEventListener("focus", touchActivity)
      window.clearInterval(interval)
    }
  }, [apiClient, currentUser?.id, mode])

  useEffect(() => {
    if (!currentUser || mode === "landing" || !realtimeClientFactory) return

    const realtimeClient = realtimeClientFactory({
      handlers: {
        onMessage: applyRealtimeMessage,
        onMention: handleMentionNotification,
        onBufferMessage: applyRealtimeMessage,
        onBufferJoined: applyAuthoritativeJoinedTopic,
        onBufferLeft: applyBufferLeft,
        onBufferRead: applyBufferRead,
        onPresenceDiff: applyPresenceDiff,
        onPresenceSync: applyPresenceSync,
        onServerStatus: applyServerStatus,
        onNotificationMention: handleMentionNotification,
        onOpen: () => {
          setConnectionHealth("connected")
          defer(reconcileAllBuffers)
        },
        onClose: () => setConnectionHealth("reconnecting"),
        onError: () => setConnectionHealth("degraded"),
        onJoinOk: () => {
          setConnectionHealth("connected")
          defer(reconcileAllBuffers)
        },
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
  const serverMessages = activeServer ? messagesByServer[activeServer.id] || [] : []
  const users = activeChannel ? usersByChannel[activeChannel.id] || [] : []

  useEffect(() => {
    if (mode === "landing" || view !== "chat" || !activeChannel?.id?.startsWith("channel:")) return
    if ((activeChannel.unread_count || 0) === 0 && (activeChannel.mention_count || 0) === 0) return

    markBufferRead(activeChannel.id)
  }, [mode, view, activeChannel?.id, activeChannel?.unread_count, activeChannel?.mention_count])

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
    const backendTopic = backendTopicFor(normalized, topics)
    const topicId = numericId(normalized.id) || numericId(backendTopic?.id)

    if (currentUser && topicId) {
      const rejectionVersions = new Map(joinRejectionVersionsRef.current)

      try {
        const joined = await apiClient.joinTopic(topicId)
        applyJoinedTopic(joined, false, rejectionVersions)
        return
      } catch (_error) {
        return
      }
    }

    if (currentUser) return

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

  function applyAuthoritativeJoinedTopic(payload) {
    applyJoinedTopic(payload, true)
  }

  function applyJoinedTopic(
    {connection, buffer, topic},
    authoritative = false,
    rejectionVersions = new Map(joinRejectionVersionsRef.current)
  ) {
    if (!connection || !buffer) return

    if (authoritative) {
      rejectedBufferIdsRef.current.delete(buffer.buffer_id)
    } else if (rejectedBufferIdsRef.current.has(buffer.buffer_id)) {
      const previousVersion = rejectionVersions.get(buffer.buffer_id) || 0
      const currentVersion = joinRejectionVersionsRef.current.get(buffer.buffer_id) || 0
      if (currentVersion > previousVersion) return false
      rejectedBufferIdsRef.current.delete(buffer.buffer_id)
    }

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
      [channel.id]: current[channel.id] || [],
    }))
    setActiveServerId(connectionId)
    setActiveChannelId(channel.id)
    setView("chat")
    return true
  }

  async function joinManualServer(form) {
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
        nickname: defaultIrcNick(currentUser),
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
    connection,
    membership,
    rejectionVersions = new Map(joinRejectionVersionsRef.current)
  ) {
    if (!connection || !membership) return

    const connectionId = `server:${connection.id}`
    const bufferId = `channel:${membership.id}`

    if (rejectedBufferIdsRef.current.has(bufferId)) {
      const previousVersion = rejectionVersions.get(bufferId) || 0
      const currentVersion = joinRejectionVersionsRef.current.get(bufferId) || 0
      if (currentVersion > previousVersion) return false
      rejectedBufferIdsRef.current.delete(bufferId)
    }

    const channel = {
      id: bufferId,
      channel_membership_id: membership.id,
      channel: membership.channel,
      topic: `on ${connection.host}`,
      unread_count: membership.unread_count,
      mention_count: membership.mention_count,
    }

    setConnections((current) => {
      const existingConnection = current.find((item) => item.server_connection_id === connection.id || item.id === connectionId)

      if (existingConnection) {
        return current.map((item) => {
          if (item.id !== existingConnection.id) return item

          return {
            ...item,
            status: connection.status,
            channels: item.channels.some((existing) => existing.id === channel.id) ? item.channels : [...item.channels, channel],
          }
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
      [channel.id]: current[channel.id] || [],
    }))
    setActiveServerId(connectionId)
    setActiveChannelId(channel.id)
    setView("chat")
    return true
  }

  function applyChannelDirectory(directory) {
    const server = connectionsRef.current.find((connection) => connection.server_connection_id === directory?.server_connection_id)
    if (!server) return

    activeServerIdRef.current = server.id
    viewRef.current = "directory"
    setActiveServerId(server.id)
    setChannelDirectory({serverId: server.id, channels: directory.channels || [], status: "ready", error: null, joinError: null, joiningChannel: null})
    setView("directory")
  }

  async function openChannelDirectory(server) {
    if (!server) return
    const requestId = ++channelDirectoryRequestRef.current

    activeServerIdRef.current = server.id
    viewRef.current = "directory"
    setActiveServerId(server.id)
    setChannelDirectory({serverId: server.id, channels: [], status: "loading", error: null, joinError: null, joiningChannel: null})
    setView("directory")

    if (!server.server_connection_id || !realtimeClientRef.current) {
      setChannelDirectory((current) => current.serverId === server.id ? {...current, status: "error", error: "Connect to this server before browsing its channels."} : current)
      return
    }

    try {
      const reply = await realtimeClientRef.current.push("server:list", {server_connection_id: server.server_connection_id})
      if (requestId !== channelDirectoryRequestRef.current || viewRef.current !== "directory" || activeServerIdRef.current !== server.id) return
      applyChannelDirectory(reply.directory)
    } catch (error) {
      setChannelDirectory((current) => current.serverId === server.id ? {...current, status: "error", error: channelDirectoryError(error?.reason), joiningChannel: null} : current)
    }
  }

  async function joinDirectoryChannel(channelName) {
    const server = connectionsRef.current.find((connection) => connection.id === channelDirectory.serverId)
    if (!server?.server_connection_id || !channelName) return

    const channel = channelName.trim()
    const rejectionVersions = new Map(joinRejectionVersionsRef.current)
    setChannelDirectory((current) => ({...current, joinError: null, joiningChannel: channel}))

    try {
      const joined = await apiClient.joinChannel(server.server_connection_id, channel)
      const applied = applyJoinedChannel(
        {...server, id: server.server_connection_id},
        joined.channel,
        rejectionVersions
      )

      if (!applied) {
        setChannelDirectory((current) => ({
          ...current,
          joinError: `Could not join ${channel}. Check the name and channel permissions, then try Join again.`,
          joiningChannel: null,
        }))
      }
    } catch (_error) {
      setChannelDirectory((current) => ({...current, joinError: "Could not join " + channel + ". Check the name and channel permissions, then try Join again.", joiningChannel: null}))
    }
  }

  async function sendMessage(event) {
    event.preventDefault()
    if (!draft.trim()) return

    const body = draft.trim()

    if (body.startsWith("/")) {
      const bufferId = currentBufferId()

      if (!realtimeClientRef.current || !bufferId) {
        setComposerError("Choose a connected server or channel before running a command.")
        return
      }

      const directoryRequestId = body.toLowerCase() === "/list" ? ++channelDirectoryRequestRef.current : null
      const commandId = globalThis.crypto?.randomUUID?.() || `command-${Date.now()}`
      setComposerError(null)

      try {
        const reply = await realtimeClientRef.current.push("command:run", {
          command_id: commandId,
          input: body,
          buffer_id: bufferId,
        })

        setDraft("")
        if (reply.directory) {
          if (directoryRequestId !== channelDirectoryRequestRef.current) return
          applyChannelDirectory(reply.directory)
        }
      } catch (error) {
        setComposerError(commandErrorMessage(error))
      }

      return
    }

    if (view === "server") {
      setComposerError("Server buffers accept commands only. Try /msg NickServ help or /quote WHOIS nick.")
      return
    }

    if (!activeChannel) {
      setComposerError("Choose a channel before sending a message.")
      return
    }
    if (isRealtimeChannel(activeChannel) && !realtimeReadyFor(activeChannel, connectionHealth)) return
    setComposerError(null)

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
    if (!activeChannel || !isRealtimeChannel(activeChannel) || !realtimeClientRef.current || !realtimeReadyFor(activeChannel, connectionHealth)) return

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
    if (!isBackendBufferId(bufferId)) return

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

    if (viewRef.current === "chat" && activeChannelIdRef.current === bufferId) {
      defer(() => markBufferRead(bufferId))
    }
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
        connection.server_connection_id === payload.server_connection_id
          ? {...connection, status: payload.status, nickname: payload.nickname || connection.nickname}
          : connection
      )
    )

    if (payload.status === "connected") {
      defer(() => reconcileServerBuffers(payload.server_connection_id))
    }
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

    rejectedBufferIdsRef.current.add(channelId)
    joinRejectionVersionsRef.current.set(
      channelId,
      (joinRejectionVersionsRef.current.get(channelId) || 0) + 1
    )

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
    setCommandCatalog(bootstrap.command_catalog || [])

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
            (bootstrap.messages_by_buffer || {})[connection.id]?.map(normalizeMessage) || [],
          ])
        )
      )
    } else {
      setConnections([])
      setMessagesByServer({})
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

    reconcileBootstrapCursors(bootstrap.message_cursors_by_buffer || {})
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
      channelDirectory={channelDirectory}
      connections={connections}
      currentUser={currentUser}
      commandCatalog={commandCatalog}
      composerError={composerError}
      draft={draft}
      messages={messages}
      notificationState={notificationState}
      serverMessages={serverMessages}
      topics={topics}
      users={users}
      view={view}
      onDiscover={() => {
        channelDirectoryRequestRef.current += 1
        viewRef.current = "discover"
        setView("discover")
      }}
      onJoinDirectoryChannel={joinDirectoryChannel}
      onJoinManualServer={joinManualServer}
      onLeaveChannel={leaveChannel}
      onMarkChannelRead={markChannelRead}
      onRequestNotifications={requestNotifications}
      onOpenChannelDirectory={openChannelDirectory}
      onDisconnectServer={disconnectServer}
      onLeaveServer={leaveServer}
      onReconnectServer={reconnectServer}
      onUpdateServer={updateServerConnection}
      onSelectChannel={(channel) => {
        channelDirectoryRequestRef.current += 1
        viewRef.current = "chat"
        activeServerIdRef.current = channel.connection?.id || activeServerId
        setActiveServerId(channel.connection?.id || activeServerId)
        setActiveChannelId(channel.id)
        setView("chat")
      }}
      onSelectServer={(server) => {
        channelDirectoryRequestRef.current += 1
        viewRef.current = "server"
        activeServerIdRef.current = server.id
        setActiveServerId(server.id)
        setView("server")
      }}
      onSelectTopic={selectTopic}
      onRetryMessage={retryMessage}
      onRetryRealtime={retryRealtimeConnection}
      onSendMessage={sendMessage}
      onLoadOlderMessages={loadOlderMessages}
      onReadingStateChange={updateBufferReadingState}
      onShowChat={() => {
        channelDirectoryRequestRef.current += 1
        viewRef.current = "chat"
        setView("chat")
      }}
      onUpdateDraft={(value) => {
        setDraft(value)
        setComposerError(null)
      }}
      connectionHealth={connectionHealth}
    />
  )

  async function markChannelRead(channel) {
    return markBufferRead(channel?.id)
  }

  async function markBufferRead(bufferId) {
    if (!bufferId || !realtimeClientRef.current) return

    try {
      await realtimeClientRef.current.push("buffer:read", {buffer_id: bufferId})
      applyBufferRead({buffer_id: bufferId, unread_count: 0, mention_count: 0})
    } catch (_error) {
      // Keep counters as-is if the backend rejects the read marker.
    }
  }

  function reconcileBootstrapCursors(cursorsByBuffer) {
    Object.keys(cursorsByBuffer).forEach((bufferId) => {
      reconcileBufferMessages(bufferId)
    })
  }

  function reconcileServerBuffers(serverConnectionId) {
    const server = connectionsRef.current.find((connection) => connection.server_connection_id === serverConnectionId)
    if (!server) return

    const bufferIds = [server.id, ...server.channels.map((channel) => channel.id)]
    bufferIds.forEach((bufferId) => reconcileBufferMessages(bufferId))
  }

  function reconcileAllBuffers() {
    connectionsRef.current.forEach((server) => {
      const bufferIds = [server.id, ...server.channels.map((channel) => channel.id)]
      bufferIds.forEach((bufferId) => reconcileBufferMessages(bufferId))
    })
  }

  function reconcileBufferMessages(bufferId) {
    if (!isBackendBufferId(bufferId)) return
    if (reconcilingBuffersRef.current.has(bufferId)) return

    reconcilingBuffersRef.current.add(bufferId)

    const currentMessages = bufferId.startsWith("server:")
      ? messagesByServerRef.current[bufferId] || []
      : messagesByChannelRef.current[bufferId] || []
    const commandIds = [...new Set(currentMessages
      .filter((message) =>
        message.kind === "command" && ["sent", "acknowledged"].includes(message.metadata?.command_status)
      )
      .map((message) => message.metadata?.command_id)
      .filter(Boolean))]
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
      .finally(() => {
        reconcilingBuffersRef.current.delete(bufferId)
      })
  }

  function retryRealtimeConnection() {
    if (!realtimeClientRef.current?.reconnect) return

    setConnectionHealth("reconnecting")
    realtimeClientRef.current.reconnect()
  }

  async function leaveChannel(channel) {
    if (!channel?.id || !realtimeClientRef.current) return

    try {
      await realtimeClientRef.current.push("channel:leave", {buffer_id: channel.id})
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
        port: Number(form.port) || 6669,
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
            <a className="rounded-md bg-white px-4 py-2.5 text-sm font-semibold text-cyan-950 transition hover:bg-cyan-100" href="/chat">
              Open chat
            </a>
            {!currentUser && developerOauth && (
              <a
                className="rounded-md border border-slate-700 px-4 py-2.5 text-sm font-semibold text-slate-200 transition hover:border-cyan-300 hover:text-white"
                href="/auth/developer"
              >
                Developer OAuth
              </a>
            )}
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
    <main className="min-h-dvh overflow-hidden bg-[#0a0d12] text-slate-100">
      <div
        className={[
          "grid h-dvh grid-cols-1",
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
          ) : props.view === "directory" ? (
            <ChannelDirectoryPane
              directory={props.channelDirectory}
              onJoinChannel={props.onJoinDirectoryChannel}
              onRefresh={() => props.onOpenChannelDirectory(props.activeServer)}
              server={props.activeServer}
            />
          ) : props.view === "server" ? (
            <ServerBufferPane
              commandCatalog={props.commandCatalog}
              composerError={props.composerError}
              draft={props.draft}
              messages={props.serverMessages}
              onLoadOlderMessages={props.onLoadOlderMessages}
              onReadingStateChange={props.onReadingStateChange}
              onReconnectServer={props.onReconnectServer}
              server={props.activeServer}
              onSendMessage={props.onSendMessage}
              onUpdateDraft={props.onUpdateDraft}
              connectionHealth={props.connectionHealth}
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
            onOpenChannelDirectory={(server) => {
              props.onOpenChannelDirectory(server)
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

function LeftSidebar({activeChannel, activeServer, connections, currentUser, mobile = false, view, onDiscover, onDisconnectServer, onJoinManualServer, onLeaveChannel, onLeaveServer, onMarkChannelRead, onOpenChannelDirectory, onReconnectServer, onSelectChannel, onSelectServer, onShowChat, onUpdateServer}) {
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
              <button
                id={"browse-channels-" + connection.server_connection_id}
                className="grid size-7 shrink-0 place-items-center rounded text-slate-500 transition hover:bg-slate-700 hover:text-cyan-200 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-cyan-300/70"
                onClick={(event) => {
                  event.stopPropagation()
                  onOpenChannelDirectory?.(connection)
                }}
                aria-label={"Browse channels on " + connection.name}
                type="button"
              >
                <span className="hero-plus size-3.5" aria-hidden="true" />
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
                      <span className="rounded-full bg-rose-400 px-1.5 text-xs font-semibold text-rose-950">{channel.mention_count}</span>
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
          <div className="grid size-9 place-items-center rounded-md bg-emerald-300 text-sm font-bold text-emerald-950">
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

function TopBar({activeChannel, activeServer, connectionHealth, notificationState, showsUserSidebar, view, onOpenMobileMenu, onOpenMobileUsers, onRequestNotifications, onRetryRealtime}) {
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
        <ConnectionHealthIndicator status={connectionHealth} onRetry={onRetryRealtime} />
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

function ConnectionHealthIndicator({status, onRetry}) {
  const labels = {
    connected: "connected",
    degraded: "degraded",
    disconnected: "offline",
    reconnecting: "reconnecting",
  }
  const label = labels[status] || "offline"
  const canRetry = status === "degraded" || status === "disconnected" || status === "reconnecting"

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
      {canRetry && (
        <Tooltip label="Reconnect realtime socket">
          <button
            className="ml-1 grid size-5 place-items-center rounded text-slate-300 transition hover:bg-slate-800 hover:text-white"
            onClick={onRetry}
            aria-label="Retry realtime connection"
          >
            <span className="hero-arrow-path size-3.5" aria-hidden="true" />
          </button>
        </Tooltip>
      )}
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

  if (view === "directory") {
    return {
      title: `Channels on ${activeServer?.name || "server"}`,
      context: null,
      subtitle: "Browse public conversations and join with one click.",
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
    title: activeChannel?.channel || "Chat",
    context: activeChannel?.connection?.host ? `on ${activeChannel.connection.host}` : null,
    subtitle: activeChannel?.topic || "Pick a topic from the sidebar or discover view.",
  }
}

function ChannelDirectoryPane({directory, onJoinChannel, onRefresh, server}) {
  const [query, setQuery] = useState("")
  const [manualChannel, setManualChannel] = useState("")
  const normalizedQuery = query.trim().toLowerCase()
  const visibleChannels = (directory?.channels || []).filter((channel) => {
    if (!normalizedQuery) return true
    return `${channel.channel} ${channel.topic || ""}`.toLowerCase().includes(normalizedQuery)
  })

  function joinManualChannel(event) {
    event.preventDefault()
    const channel = manualChannel.trim()
    if (!channel) return
    onJoinChannel(channel)
  }

  return (
    <section id="channel-directory" className="min-h-0 flex-1 overflow-y-auto bg-[#090b10] px-4 py-5 sm:px-6 sm:py-7">
      <div className="mx-auto max-w-5xl">
        <div className="flex flex-col gap-5 border-b border-slate-800 pb-6 sm:flex-row sm:items-end sm:justify-between">
          <div className="max-w-2xl">
            <h2 className="text-2xl font-semibold tracking-tight text-white">Find your next conversation</h2>
            <p className="mt-2 text-sm leading-6 text-slate-400">
              This list comes from {server?.name || "the server"}. Private channels and channels hidden by the server will not appear.
            </p>
          </div>
          <button
            className="inline-flex h-9 shrink-0 items-center justify-center gap-2 self-start rounded-md border border-slate-700 px-3 text-sm font-medium text-slate-200 transition hover:border-cyan-300/70 hover:text-white disabled:cursor-wait disabled:opacity-60 sm:self-auto"
            disabled={directory?.status === "loading"}
            onClick={onRefresh}
            type="button"
          >
            <span className={["hero-arrow-path size-4", directory?.status === "loading" ? "animate-spin" : ""].join(" ")} aria-hidden="true" />
            Refresh list
          </button>
        </div>

        <div className="grid gap-3 py-5 md:grid-cols-[minmax(0,1fr)_minmax(18rem,0.55fr)]">
          <label className="block" htmlFor="channel-directory-search">
            <span className="mb-1.5 block text-xs font-semibold uppercase tracking-[0.14em] text-slate-500">Search this server</span>
            <span className="flex h-11 items-center gap-2 rounded-md border border-slate-700 bg-[#111620] px-3 transition focus-within:border-cyan-300/70 focus-within:ring-2 focus-within:ring-cyan-300/10">
              <span className="hero-magnifying-glass size-4 text-slate-500" aria-hidden="true" />
              <input
                id="channel-directory-search"
                className="min-w-0 flex-1 border-0 bg-transparent text-sm text-white outline-none placeholder:text-slate-600"
                onChange={(event) => setQuery(event.target.value)}
                placeholder="Try elixir, games, or music"
                type="search"
                value={query}
              />
            </span>
          </label>

          <form id="channel-directory-join-form" onSubmit={joinManualChannel}>
            <label className="mb-1.5 block text-xs font-semibold uppercase tracking-[0.14em] text-slate-500" htmlFor="channel-directory-manual">
              Know the channel name?
            </label>
            <div className="flex h-11 overflow-hidden rounded-md border border-slate-700 bg-[#111620] transition focus-within:border-cyan-300/70 focus-within:ring-2 focus-within:ring-cyan-300/10">
              <input
                id="channel-directory-manual"
                className="min-w-0 flex-1 border-0 bg-transparent px-3 text-sm text-white outline-none placeholder:text-slate-600"
                onChange={(event) => setManualChannel(event.target.value)}
                placeholder="#channel"
                value={manualChannel}
              />
              <button className="border-l border-slate-700 px-4 text-sm font-semibold text-cyan-200 transition hover:bg-cyan-300 hover:text-cyan-950" type="submit">
                Join
              </button>
            </div>
          </form>
        </div>

        {directory?.error && (
          <div className="mb-4 flex flex-col gap-3 rounded-md border border-rose-400/30 bg-rose-400/5 p-4 sm:flex-row sm:items-center sm:justify-between" role="alert">
            <div>
              <div className="text-sm font-semibold text-rose-200">The channel list did not load</div>
              <p className="mt-1 text-sm text-slate-400">{directory.error}</p>
            </div>
            <button className="shrink-0 self-start rounded-md border border-rose-300/40 px-3 py-1.5 text-sm font-semibold text-rose-100 transition hover:border-rose-200 hover:text-white" onClick={onRefresh} type="button">
              Try again
            </button>
          </div>
        )}

        {directory?.joinError && (
          <div className="mb-4 rounded-md border border-amber-300/30 bg-amber-300/5 p-4" role="alert">
            <div className="text-sm font-semibold text-amber-100">Channel was not joined</div>
            <p className="mt-1 text-sm text-slate-400">{directory.joinError}</p>
          </div>
        )}

        {directory?.status === "loading" ? (
          <div className="overflow-hidden rounded-lg border border-slate-800 bg-[#10151e]" aria-label={"Loading channels from " + (server?.name || "the server")} aria-live="polite" role="status">
            <span className="sr-only">Asking {server?.name || "the server"} for its public channels.</span>
            {[0, 1, 2].map((row) => (
              <div key={row} className="grid animate-pulse gap-3 border-b border-slate-800/90 px-4 py-5 last:border-b-0 sm:grid-cols-[minmax(0,1fr)_5rem]">
                <div>
                  <div className="h-3 w-28 rounded bg-slate-700/80" />
                  <div className="mt-3 h-2.5 w-3/5 rounded bg-slate-800" />
                </div>
                <div className="h-9 rounded-md bg-slate-800" />
              </div>
            ))}
          </div>
        ) : directory?.status === "ready" && visibleChannels.length === 0 ? (
          <div className="border-y border-slate-800 py-12 text-center">
            <span className="hero-magnifying-glass mx-auto block size-6 text-slate-600" aria-hidden="true" />
            <p className="mt-3 text-sm font-medium text-slate-300">No matching channels found.</p>
            <p className="mt-1 text-sm text-slate-500">Try a broader search, refresh the list, or join by name.</p>
          </div>
        ) : directory?.status === "ready" ? (
          <div className="overflow-hidden rounded-lg border border-slate-800 bg-[#10151e]">
            <div className="flex items-center justify-between border-b border-slate-800 px-4 py-3 text-xs font-semibold uppercase tracking-[0.14em] text-slate-500" aria-live="polite" role="status">
              <span>{visibleChannels.length} {visibleChannels.length === 1 ? "channel" : "channels"}</span>
              <span>Join a channel</span>
            </div>
            <div className="divide-y divide-slate-800/90">
              {visibleChannels.map((channel) => {
                const joining = directory.joiningChannel === channel.channel
                return (
                  <article key={channel.channel} className="group grid gap-3 px-4 py-4 transition hover:bg-slate-900/70 sm:grid-cols-[minmax(0,1fr)_auto] sm:items-center">
                    <div className="min-w-0">
                      <div className="flex flex-wrap items-center gap-x-3 gap-y-1">
                        <h3 className="font-mono text-sm font-semibold text-cyan-200">{channel.channel}</h3>
                        <span className="text-xs tabular-nums text-slate-500">{channel.users} {channel.users === 1 ? "person" : "people"}</span>
                      </div>
                      <p className="mt-1.5 truncate text-sm text-slate-400" title={channel.topic || "No topic set"}>{channel.topic || "No topic set"}</p>
                    </div>
                    <button
                      className={[
                        "h-9 rounded-md px-4 text-sm font-semibold transition disabled:cursor-wait",
                        joining ? "bg-slate-700 text-white/70" : "bg-cyan-300 text-cyan-950 hover:bg-white",
                      ].join(" ")}
                      disabled={joining}
                      onClick={() => onJoinChannel(channel.channel)}
                      type="button"
                    >
                      {joining ? "Joining…" : "Join"}
                    </button>
                  </article>
                )
              })}
            </div>
          </div>
        ) : null}
      </div>
    </section>
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

function ServerBufferPane({commandCatalog, composerError, connectionHealth, draft, messages, onLoadOlderMessages, onReadingStateChange, onReconnectServer, server, onSendMessage, onUpdateDraft}) {
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
        commandCatalog={commandCatalog}
        context="server"
        error={composerError}
        inputId="server-command-input"
        draft={draft}
        disabled={server.status !== "connected" || connectionHealth !== "connected"}
        statusLabel={composerStatusLabel(server.status, connectionHealth)}
        onSendMessage={onSendMessage}
        onUpdateDraft={onUpdateDraft}
        placeholder="Try /msg NickServ help or /quote WHOIS nick"
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
          className="rounded-md border border-amber-200/40 px-3 py-1.5 text-xs font-semibold text-amber-50 transition hover:border-amber-100 hover:bg-amber-100 hover:text-amber-950"
          onClick={() => onReconnectServer?.(server)}
          type="button"
        >
          Reconnect
        </button>
      )}
    </div>
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
          <a className="block rounded-md bg-white px-4 py-2.5 text-center text-sm font-semibold text-cyan-950 hover:bg-cyan-100" href={`/auth/google?topic=${topicParam}`}>
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
  const [form, setForm] = useState({host: "127.0.0.1", port: "6669", channels: "#elixir, #phoenix", useTls: false})

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
          <button className="flex-1 rounded-md bg-cyan-300 px-4 py-2 text-sm font-semibold text-cyan-950 hover:bg-white">
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
    port: String(server.port || 6669),
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
          <button className="flex-1 rounded-md bg-cyan-300 px-4 py-2 text-sm font-semibold text-cyan-950 hover:bg-white">
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
          <button className="flex-1 rounded-md bg-rose-300 px-4 py-2 text-sm font-semibold text-rose-950 hover:bg-white" onClick={onConfirm} type="button">
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

function isBackendBufferId(bufferId) {
  return bufferId?.startsWith("channel:") || bufferId?.startsWith("server:")
}

function defer(callback) {
  if (typeof queueMicrotask === "function") {
    queueMicrotask(callback)
    return
  }

  Promise.resolve().then(callback)
}

function numericId(value) {
  const parsed = Number(value)
  return Number.isInteger(parsed) ? parsed : null
}

function backendTopicFor(topic, topics) {
  return topics.find((candidate) => {
    const normalized = normalizeTopic(candidate)

    return (
      numericId(normalized.id) &&
      normalized.channel === topic.channel &&
      normalized.server_host === topic.server_host &&
      Number(normalized.server_port || 6669) === Number(topic.server_port || 6669)
    )
  })
}

function topicForRequestedId(requestedId, topics) {
  const directMatch = topics.find((topic) => String(topic.id) === String(requestedId))
  if (directMatch) return directMatch

  const demoMatch = demoTopics.find((topic) => String(topic.id) === String(requestedId))
  if (!demoMatch) return null

  return backendTopicFor(normalizeTopic(demoMatch), topics) || null
}

function defaultIrcNick(currentUser) {
  const localPart = currentUser?.email?.split("@")[0] || ""
  let nick = localPart.replace(/[^A-Za-z0-9_\-[\]`^{}\\]/g, "_").replace(/^[_-]+|[_-]+$/g, "")

  if (!nick) nick = "topics_user"
  if (!/^[A-Za-z_\-[\]`^{}\\]/.test(nick)) nick = `u_${nick}`

  return nick.slice(0, 24)
}

function requestedTopicId() {
  if (typeof window === "undefined") return null

  return new URLSearchParams(window.location.search).get("topic")
}

function commandErrorMessage(error) {
  if (error?.error?.message) {
    const usage = error.error.usage ? ` Usage: ${error.error.usage}` : ""
    return `${error.error.message}${usage}`
  }

  const messages = {
    invalid_buffer: "Choose a server or channel where this command can run.",
    invalid_command_args: "The command arguments are incomplete or invalid.",
    joining_channel: "Wait for the channel join to finish, then try again.",
    not_connected: "Reconnect to the IRC server before running this command.",
    not_joined: "Join that channel before sending to it.",
    unknown_command: "That slash command is not supported.",
  }

  return messages[error?.reason] || "The IRC command could not be sent."
}

function channelDirectoryError(reason) {
  if (reason === "list_in_progress") return "This server is already preparing a channel list. Try again in a moment."
  if (reason === "list_timeout") return "The server took too long to return its channel list."
  if (reason === "not_connected") return "Reconnect to this server before browsing its channels."
  return "The server could not return its channel list. Try again shortly."
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
