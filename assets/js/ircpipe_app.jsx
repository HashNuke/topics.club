import {useEffect, useMemo, useRef, useState} from "react"
import {createApiClient} from "./api_client.js"
import ChannelDirectoryPane from "./components/channel_directory_pane.jsx"
import DiscoverPane from "./components/discover_pane.jsx"
import LandingPage from "./components/landing_page.jsx"
import ChatPane, {
  isRealtimeChannel,
  realtimeReadyFor,
} from "./components/chat_pane.jsx"
import LeftSidebar from "./components/left_sidebar.jsx"
import MobileDrawer, {MobileDrawerHeader} from "./components/mobile_drawer.jsx"
import RightSidebar from "./components/right_sidebar.jsx"
import ServerBufferPane from "./components/server_buffer_pane.jsx"
import TopBar from "./components/top_bar.jsx"
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
export {default as TopicGrid} from "./components/topic_grid.jsx"
export {default as LandingPage} from "./components/landing_page.jsx"

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
