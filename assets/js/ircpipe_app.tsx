import React, {useEffect, useMemo, useRef, useState} from "react"
import {createApiClient, type ApiClient} from "./api_client.ts"
import {commandErrorMessage, type CommandError} from "./app_feedback.ts"
import {buildBootstrapState, type BootstrapPayload} from "./bootstrap_state.ts"
import {
  notificationPermission,
  requestNotificationPermission,
  showMentionNotification,
} from "./browser_notifications.ts"
import AppShell from "./components/app_shell.tsx"
import LandingPage from "./components/landing_page.tsx"
import {
  isRealtimeChannel,
  realtimeReadyFor,
} from "./components/chat_pane.tsx"
import {
  applyUserDiff,
  normalizeMessage,
  normalizeTopic,
} from "./chat_store.ts"
import {requestedTopicId, topicForRequestedId} from "./topic_navigation.ts"
import useActivityHeartbeat from "./hooks/use_activity_heartbeat.ts"
import useBufferMessages from "./hooks/use_buffer_messages.ts"
import useChannelDirectory from "./hooks/use_channel_directory.ts"
import useRealtimeConnection from "./hooks/use_realtime_connection.ts"
import useServerConnections from "./hooks/use_server_connections.ts"
import type {RealtimeClient, RealtimeHandlers} from "./realtime_client.ts"
import type {
  AppView,
  Channel,
  ChannelDirectory,
  ChatMessage,
  CommandCatalogEntry,
  CurrentUser,
  PresenceDiffPayload,
  PresenceSyncPayload,
  ServerConnection,
  Topic,
  UsersByBuffer,
} from "./types.ts"
export {appendTimelineMessage, trimMessagesToLimit} from "./chat_store.ts"
export {MESSAGE_RENDER_LIMIT, visibleTimelineMessages} from "./components/chat_pane.tsx"
export {default as TopicGrid} from "./components/topic_grid.tsx"
export {default as LandingPage} from "./components/landing_page.tsx"

const csrfToken = document.querySelector("meta[name='csrf-token']")?.getAttribute("content")

export interface IrcpipeAppProps {
  apiClient?: ApiClient
  appMode?: "landing" | "chat"
  currentUser?: CurrentUser | null
  developerOauth: boolean
  realtimeClientFactory?: ((options: {handlers: RealtimeHandlers}) => RealtimeClient) | null
}

export default function IrcpipeApp({apiClient: providedApiClient, appMode, currentUser, developerOauth, realtimeClientFactory}: IrcpipeAppProps) {
  const apiClient = useMemo(() => providedApiClient || createApiClient({csrfToken}), [providedApiClient])
  const mode = appMode || (currentUser ? "chat" : "landing")
  const [topics, setTopics] = useState<Topic[]>([])
  const [topicsLoaded, setTopicsLoaded] = useState(false)
  const [authTopic, setAuthTopic] = useState<Topic | null>(null)
  const [view, setView] = useState<AppView>("chat")
  const [notificationState, setNotificationState] = useState<NotificationPermission | "unsupported">(notificationPermission())
  const [activeChannelId, setActiveChannelId] = useState<string | null>(null)
  const [activeServerId, setActiveServerId] = useState<string | null>(null)
  const [usersByChannel, setUsersByChannel] = useState<UsersByBuffer>({})
  const [draft, setDraft] = useState("")
  const [composerError, setComposerError] = useState<string | null>(null)
  const [commandCatalog, setCommandCatalog] = useState<CommandCatalogEntry[]>([])
  const activeChannelIdRef = useRef(activeChannelId)
  const activeServerIdRef = useRef(activeServerId)
  const connectionsRef = useRef<ServerConnection[]>([])
  const notificationStateRef = useRef(notificationState)
  const requestedTopicIdRef = useRef(requestedTopicId())
  const realtimeClientRef = useRef<RealtimeClient | null>(null)
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

  function selectTopic(topic: Topic): void {
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

  async function sendMessage(event: React.FormEvent<HTMLFormElement>): Promise<void> {
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
        const reply = await realtimeClientRef.current.push<{directory?: ChannelDirectory}>("command:run", {
          command_id: commandId,
          input: body,
          buffer_id: bufferId,
        })

        setDraft("")
        if (reply.directory) {
          applyChannelDirectory(reply.directory, directoryRequestId ?? undefined)
        }
      } catch (error: unknown) {
        setComposerError(commandErrorMessage(error as CommandError))
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

    const nextMessage: ChatMessage = {
      id: `${view}-${Date.now()}`,
      occurredAt: new Date().toISOString(),
      nick: currentUser?.email?.split("@")[0] || "you",
      body,
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
        const reply = await realtimeClientRef.current.push<{message: ChatMessage}>("message:send", {
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

  async function retryMessage(message: ChatMessage): Promise<void> {
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
      const reply = await realtimeClientRef.current.push<{message: ChatMessage}>("message:send", {
        client_message_id: clientMessageId,
        buffer_id: activeChannel.id,
        body: message.body,
      })

      replacePendingMessage(activeChannel.id, clientMessageId, normalizeMessage(reply.message))
    } catch (_error) {
      markPendingFailed(activeChannel.id, clientMessageId)
    }
  }

  function currentBufferId(): string | undefined {
    if (view === "server" && activeServer) return `server:${activeServer.server_connection_id || activeServer.id}`
    return activeChannel?.id
  }

  async function requestNotifications(): Promise<void> {
    setNotificationState(await requestNotificationPermission())
  }

  function applyPresenceSync(payload: PresenceSyncPayload): void {
    setUsersByChannel((current) => ({
      ...current,
      [payload.buffer_id]: payload.users || [],
    }))
  }

  function applyPresenceDiff(payload: PresenceDiffPayload): void {
    setUsersByChannel((current) => ({
      ...current,
      [payload.buffer_id]: applyUserDiff(current[payload.buffer_id] || [], payload.diff),
    }))
  }

  function handleMentionNotification(message: ChatMessage): void {
    showMentionNotification(message, {
      currentUser,
      notificationState: notificationStateRef.current,
    })
  }

  function applyBootstrap(bootstrap: BootstrapPayload): void {
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
      onSelectChannel={(channel: Channel) => {
        cancelChannelDirectory()
        viewRef.current = "chat"
        activeServerIdRef.current = channel.connection?.id || activeServerId
        setActiveServerId(channel.connection?.id || activeServerId)
        setActiveChannelId(channel.id)
        setView("chat")
      }}
      onSelectServer={(server: ServerConnection) => {
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
      onUpdateDraft={(value: string) => {
        setDraft(value)
        setComposerError(null)
      }}
      connectionHealth={connectionHealth}
    />
  )

  async function markChannelRead(channel: Channel): Promise<void> {
    return markBufferRead(channel?.id)
  }

  async function markBufferRead(bufferId?: string | null): Promise<void> {
    if (!bufferId || !realtimeClientRef.current) return

    try {
      await realtimeClientRef.current.push("buffer:read", {buffer_id: bufferId})
      applyBufferRead({buffer_id: bufferId, unread_count: 0, mention_count: 0})
    } catch (_error) {
      // Keep counters as-is if the backend rejects the read marker.
    }
  }

}
