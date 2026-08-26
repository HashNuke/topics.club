import {useEffect, useMemo, useRef, useState} from "react"
import {createApiClient} from "./api_client.js"
import {commandErrorMessage} from "./app_feedback.js"
import {buildBootstrapState} from "./bootstrap_state.js"
import {
  notificationPermission,
  requestNotificationPermission,
  showMentionNotification,
} from "./browser_notifications.js"
import {
  channelFromBuffer,
  channelFromMembership,
  planServerRemoval,
  removeChannel,
  updateBufferRead,
  updateConnectionDetails,
  updateServerStatus,
  upsertJoinedChannel,
} from "./connection_store.js"
import AppShell from "./components/app_shell.jsx"
import LandingPage from "./components/landing_page.jsx"
import {
  isRealtimeChannel,
  realtimeReadyFor,
} from "./components/chat_pane.jsx"
import {
  applyUserDiff,
  normalizeChannel,
  normalizeMessage,
  normalizeTopic,
} from "./chat_store.js"
import {backendTopicFor, numericId, requestedTopicId, topicForRequestedId} from "./topic_navigation.js"
import useActivityHeartbeat from "./hooks/use_activity_heartbeat.js"
import useBufferMessages from "./hooks/use_buffer_messages.js"
import useChannelDirectory from "./hooks/use_channel_directory.js"
import useRealtimeConnection from "./hooks/use_realtime_connection.js"
export {appendTimelineMessage, trimMessagesToLimit} from "./chat_store.js"
export {MESSAGE_RENDER_LIMIT, visibleTimelineMessages} from "./components/chat_pane.jsx"
export {default as TopicGrid} from "./components/topic_grid.jsx"
export {default as LandingPage} from "./components/landing_page.jsx"

const csrfToken = document.querySelector("meta[name='csrf-token']")?.getAttribute("content")

export default function IrcpipeApp({apiClient: providedApiClient, appMode, currentUser, developerOauth, realtimeClientFactory}) {
  const apiClient = useMemo(() => providedApiClient || createApiClient({csrfToken}), [providedApiClient])
  const mode = appMode || (currentUser ? "chat" : "landing")
  const [topics, setTopics] = useState([])
  const [topicsLoaded, setTopicsLoaded] = useState(false)
  const [authTopic, setAuthTopic] = useState(null)
  const [view, setView] = useState("chat")
  const [notificationState, setNotificationState] = useState(notificationPermission())
  const [connections, setConnections] = useState([])
  const [activeChannelId, setActiveChannelId] = useState(null)
  const [activeServerId, setActiveServerId] = useState(null)
  const [usersByChannel, setUsersByChannel] = useState({})
  const [draft, setDraft] = useState("")
  const [composerError, setComposerError] = useState(null)
  const [commandCatalog, setCommandCatalog] = useState([])
  const activeChannelIdRef = useRef(activeChannelId)
  const activeServerIdRef = useRef(activeServerId)
  const connectionsRef = useRef(connections)
  const rejectedBufferIdsRef = useRef(new Set())
  const joinRejectionVersionsRef = useRef(new Map())
  const notificationStateRef = useRef(notificationState)
  const requestedTopicIdRef = useRef(requestedTopicId())
  const realtimeClientRef = useRef(null)
  const viewRef = useRef(view)

  const {
    applyChannelDirectory,
    beginChannelDirectoryRequest,
    cancelChannelDirectory,
    channelDirectory,
    joinDirectoryChannel,
    openChannelDirectory,
  } = useChannelDirectory({
    activeServerIdRef,
    apiClient,
    applyJoinedChannel,
    connectionsRef,
    joinRejectionVersionsRef,
    realtimeClientRef,
    setActiveServerId,
    setView,
    viewRef,
  })

  const {
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
  } = useBufferMessages({
    activeChannelIdRef,
    activeServerIdRef,
    apiClient,
    connectionsRef,
    markBufferRead,
    viewRef,
  })

  const {connectionHealth, retryRealtimeConnection} = useRealtimeConnection({
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
    },
    onConnected: reconcileAllBuffers,
    realtimeClientFactory,
    realtimeClientRef,
    sessionKey: currentUser && mode !== "landing" ? currentUser.id : null,
  })

  useEffect(() => {
    connectionsRef.current = connections
  }, [connections])

  useEffect(() => {
    viewRef.current = view
  }, [view])

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

  useActivityHeartbeat(apiClient, Boolean(currentUser && mode !== "landing"))

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
    const channel = channelFromBuffer(buffer, topic)

    setConnections((current) => upsertJoinedChannel(current, connection, channel))

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

    const channel = channelFromMembership(membership, connection.host)

    setConnections((current) => upsertJoinedChannel(current, connection, channel, {updateStatus: true}))

    setMessagesByChannel((current) => ({
      ...current,
      [channel.id]: current[channel.id] || [],
    }))
    setActiveServerId(connectionId)
    setActiveChannelId(channel.id)
    setView("chat")
    return true
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

      const directoryRequestId = body.toLowerCase() === "/list" ? beginChannelDirectoryRequest() : null
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
          applyChannelDirectory(reply.directory, directoryRequestId)
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
        [activeServer.id]: [...(current[activeServer.id] || []), nextMessage],
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

  async function requestNotifications() {
    setNotificationState(await requestNotificationPermission())
  }

  function applyServerStatus(payload) {
    setConnections((current) => updateServerStatus(current, payload))

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

    setConnections((current) => removeChannel(current, channelId))
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

    setConnections((current) => updateBufferRead(current, payload))
  }

  function handleMentionNotification(message) {
    showMentionNotification(message, {
      currentUser,
      notificationState: notificationStateRef.current,
    })
  }

  function applyBootstrap(bootstrap) {
    const state = buildBootstrapState(bootstrap)
    if (!state) return

    if (state.topics) setTopics(state.topics)
    if (state.notificationState) setNotificationState(state.notificationState)
    setCommandCatalog(state.commandCatalog)
    setConnections(state.connections)
    setMessagesByServer(state.messagesByServer)
    setMessagesByChannel(state.messagesByChannel)
    setUsersByChannel(state.usersByChannel)
    if (state.activeChannelId) setActiveChannelId(state.activeChannelId)
    if (state.activeServerId) setActiveServerId(state.activeServerId)
    if (state.view) setView(state.view)
    reconcileBootstrapCursors(state.cursorsByBuffer)
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
        cancelChannelDirectory()
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
        cancelChannelDirectory()
        viewRef.current = "chat"
        activeServerIdRef.current = channel.connection?.id || activeServerId
        setActiveServerId(channel.connection?.id || activeServerId)
        setActiveChannelId(channel.id)
        setView("chat")
      }}
      onSelectServer={(server) => {
        cancelChannelDirectory()
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
        cancelChannelDirectory()
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

    setConnections((current) => updateConnectionDetails(current, connection))
  }

  function applyServerDeleted(payload) {
    const currentConnections = connectionsRef.current
    const removal = planServerRemoval(currentConnections, payload.server_connection_id)
    if (!removal) return

    const {deletedChannelIds, deletedServer, nextChannel, nextConnections, nextServer} = removal

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

function defer(callback) {
  if (typeof queueMicrotask === "function") {
    queueMicrotask(callback)
    return
  }

  Promise.resolve().then(callback)
}
