import React, {useEffect, useMemo, useRef, useState} from "react"
import {createApiClient} from "./api_client.js"
import {commandErrorMessage} from "./app_feedback.ts"
import {buildBootstrapState} from "./bootstrap_state.ts"
import {
  notificationPermission,
  requestNotificationPermission,
  showMentionNotification,
} from "./browser_notifications.ts"
import AppShell from "./components/app_shell.jsx"
import LandingPage from "./components/landing_page.jsx"
import {
  isRealtimeChannel,
  realtimeReadyFor,
} from "./components/chat_pane.jsx"
import {
  applyUserDiff,
  normalizeMessage,
  normalizeTopic,
} from "./chat_store.ts"
import {requestedTopicId, topicForRequestedId} from "./topic_navigation.ts"
import useActivityHeartbeat from "./hooks/use_activity_heartbeat.js"
import useBufferMessages from "./hooks/use_buffer_messages.js"
import useChannelDirectory from "./hooks/use_channel_directory.js"
import useRealtimeConnection from "./hooks/use_realtime_connection.js"
import useServerConnections from "./hooks/use_server_connections.js"
export {appendTimelineMessage, trimMessagesToLimit} from "./chat_store.ts"
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
  const [activeChannelId, setActiveChannelId] = useState(null)
  const [activeServerId, setActiveServerId] = useState(null)
  const [usersByChannel, setUsersByChannel] = useState({})
  const [draft, setDraft] = useState("")
  const [composerError, setComposerError] = useState(null)
  const [commandCatalog, setCommandCatalog] = useState([])
  const activeChannelIdRef = useRef(activeChannelId)
  const activeServerIdRef = useRef(activeServerId)
  const connectionsRef = useRef([])
  const notificationStateRef = useRef(notificationState)
  const requestedTopicIdRef = useRef(requestedTopicId())
  const realtimeClientRef = useRef(null)
  const viewRef = useRef(view)

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

  const {
    applyAuthoritativeJoinedTopic,
    applyBufferLeft,
    applyBufferRead,
    applyJoinedChannel,
    applyServerStatus,
    connections,
    disconnectServer,
    joinManualServer,
    joinRejectionVersionsRef,
    joinTopic,
    leaveChannel,
    leaveServer,
    reconnectServer,
    setConnections,
    updateServerConnection,
  } = useServerConnections({
    activeChannelIdRef,
    activeServerIdRef,
    apiClient,
    appendSystemMessage,
    canJoinTopics: Boolean(currentUser),
    connectionsRef,
    realtimeClientRef,
    reconcileServerBuffers,
    setActiveChannelId,
    setActiveServerId,
    setMessagesByChannel,
    setMessagesByServer,
    setUsersByChannel,
    setView,
    topics,
  })

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

}
