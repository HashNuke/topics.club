import React, {useEffect, useMemo, useRef, useState} from "react"
import {
  loadActiveBufferPreference,
  requestedBufferId,
  saveActiveBufferPreference,
  selectPreferredBuffer,
} from "./active_buffer_preference.ts"
import {createApiClient, type ApiClient} from "./api_client.ts"
import {commandErrorMessage, type CommandError} from "./app_feedback.ts"
import {buildBootstrapState, type BootstrapPayload} from "./bootstrap_state.ts"
import {
  createNotificationEventCoordinator,
  initialNotificationDeviceState,
  mentionNotificationEligible,
  showMentionNotification,
  type NotificationDeviceState,
} from "./browser_notifications.ts"
import {
  clearNotificationServerRegistration,
  enableNotificationDevice,
  notificationControlState,
  notificationDeliveryCoveredByPush,
  synchronizeNotificationDevice,
} from "./push_notifications.ts"
import {
  synchronizeServiceWorkerAccount,
  synchronizeServiceWorkerClientLease,
} from "./service_worker_account.ts"
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
  BackendConnection,
  BufferReadPayload,
  BufferRecord,
  Channel,
  DirectMessageBufferRecord,
  ChannelDirectory,
  ChatMessage,
  CommandCatalogEntry,
  CurrentUser,
  DirectMessageThreadPayload,
  EntityId,
  ServerChannel,
  PresenceDiffPayload,
  PresenceSyncPayload,
  NotificationPreferencePayload,
  NotificationEventPayload,
  PushConfig,
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

function notificationPreferenceKey(scope: "server" | "channel", id: EntityId): string {
  return `${scope}:${id}`
}

function validNotificationEvent(message: NotificationEventPayload): boolean {
  if (
    !message ||
    !validProtocolEntityId(message.notification_id) ||
    !validProtocolEntityId(message.server_connection_id) ||
    typeof message.buffer_id !== "string" ||
    !/^(channel|direct):[1-9][0-9]{0,18}$/.test(message.buffer_id) ||
    typeof message.nick !== "string" ||
    typeof message.body !== "string"
  ) return false

  if (typeof message.event_id !== "string") return false
  const eventId = message.event_id.trim()
  return Boolean(eventId && eventId.length <= 256)
}

function validProtocolEntityId(value: unknown): value is EntityId {
  if (typeof value === "number") return Number.isSafeInteger(value) && value > 0
  return typeof value === "string" && /^[1-9][0-9]{0,18}$/.test(value)
}

interface NotificationPreferenceOperation {
  baseRevision: number
  epoch: number
  previous: boolean
}

export default function IrcpipeApp({apiClient: providedApiClient, appMode, currentUser, developerOauth, realtimeClientFactory}: IrcpipeAppProps) {
  const apiClient = useMemo(() => providedApiClient || createApiClient({csrfToken}), [providedApiClient])
  const mode = appMode || (currentUser ? "chat" : "landing")
  const [topics, setTopics] = useState<Topic[]>([])
  const [topicsLoaded, setTopicsLoaded] = useState(false)
  const [authTopic, setAuthTopic] = useState<Topic | null>(null)
  const [view, setView] = useState<AppView>("chat")
  const [notificationDeviceState, setNotificationDeviceState] = useState<NotificationDeviceState>(initialNotificationDeviceState())
  const [notificationSavingIds, setNotificationSavingIds] = useState<Set<string>>(new Set())
  const [pushConfig, setPushConfig] = useState<PushConfig>({configured: false, vapid_public_key: null})
  const [activeChannelId, setActiveChannelId] = useState<string | null>(null)
  const [activeServerId, setActiveServerId] = useState<string | null>(null)
  const [usersByChannel, setUsersByChannel] = useState<UsersByBuffer>({})
  const [draft, setDraft] = useState("")
  const [composerError, setComposerError] = useState<string | null>(null)
  const [discoverServerChannels, setDiscoverServerChannels] = useState<ServerChannel[]>([])
  const [discoverError, setDiscoverError] = useState<string | null>(null)
  const [discoverLoading, setDiscoverLoading] = useState(false)
  const [joiningDiscoveryServerChannelId, setJoiningDiscoveryServerChannelId] = useState<string | number | null>(null)
  const [commandCatalog, setCommandCatalog] = useState<CommandCatalogEntry[]>([])
  const [bootstrapLoading, setBootstrapLoading] = useState(Boolean(currentUser && mode !== "landing"))
  const [bootstrapReady, setBootstrapReady] = useState(false)
  const activeChannelIdRef = useRef(activeChannelId)
  const activeServerIdRef = useRef(activeServerId)
  const connectionsRef = useRef<ServerConnection[]>([])
  const discoverRequestedRef = useRef(false)
  const notificationDeviceStateRef = useRef(notificationDeviceState)
  const notificationAuthorizationEpochRef = useRef(0)
  const notificationEligibilityControllersRef = useRef(new Set<AbortController>())
  const notificationOperationIdRef = useRef(0)
  const notificationPreferenceEpochRef = useRef(0)
  const notificationPreferenceOperationsRef = useRef(
    new Map<string, NotificationPreferenceOperation>()
  )
  const notificationEventCoordinatorRef = useRef<ReturnType<typeof createNotificationEventCoordinator> | null>(null)
  const queuedNotificationEventsRef = useRef<NotificationEventPayload[]>([])
  const queuedRealtimeEventsRef = useRef<Array<() => void>>([])
  const realtimeRefreshInFlightRef = useRef(false)
  const realtimeRefreshRequestedRef = useRef(false)
  const requestedBufferIdRef = useRef(requestedBufferId())
  const requestedTopicIdRef = useRef(requestedTopicId())
  const realtimeClientRef = useRef<RealtimeClient | null>(null)
  const viewRef = useRef(view)
  const pushConfigRef = useRef(pushConfig)
  const currentUserRef = useRef(currentUser)

  currentUserRef.current = currentUser
  pushConfigRef.current = pushConfig

  const notificationCoordinatorScope = String(currentUser?.id || "anonymous")

  useEffect(() => {
    const coordinator = createNotificationEventCoordinator({scope: notificationCoordinatorScope})
    notificationEventCoordinatorRef.current = coordinator

    return () => {
      coordinator.close()
      if (notificationEventCoordinatorRef.current === coordinator) {
        notificationEventCoordinatorRef.current = null
      }
    }
  }, [notificationCoordinatorScope])

  useEffect(() => {
    notificationAuthorizationEpochRef.current += 1
    abortNotificationEligibilityChecks()

    return () => {
      notificationAuthorizationEpochRef.current += 1
      abortNotificationEligibilityChecks()
    }
  }, [currentUser?.id])

  useEffect(() => {
    if (!currentUser) {
      notificationOperationIdRef.current += 1
      clearNotificationServerRegistration()
    }
    if (!("serviceWorker" in navigator)) return

    return synchronizeServiceWorkerAccount()
  }, [currentUser?.id, pushConfig.session_generation])

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
    replaceBootstrapMessages,
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
    applyDirectMessageClosed,
    applyDirectMessageThread,
    applyJoinedChannel,
    applyServerStatus,
    connections,
    closeDirectMessage,
    disconnectServer,
    joinManualServer,
    joinRejectionVersionsRef,
    joinTopic,
    leaveChannel,
    leaveServer,
    reconnectServer,
    seedDirectMessageTombstones,
    setDirectMessageBlocked,
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
      onMessage: (payload) => applyOrQueueRealtimeEvent(() => applyRealtimeMessage(payload)),
      onBufferMessage: (payload) => applyOrQueueRealtimeEvent(() => applyRealtimeMessage(payload)),
      onBufferJoined: (payload) => applyOrQueueRealtimeEvent(() => applyAuthoritativeJoinedTopic(payload)),
      onBufferLeft: (payload) => applyOrQueueRealtimeEvent(() => applyBufferLeft(payload)),
      onBufferRead: (payload) => applyOrQueueRealtimeEvent(() => applyBufferRead(payload)),
      onDirectMessageThread: (payload) => applyOrQueueRealtimeEvent(() => applyDirectMessageThread(payload)),
      onDirectMessageClosed: (payload) => applyOrQueueRealtimeEvent(() => applyDirectMessageClosed(payload)),
      onPresenceDiff: (payload) => applyOrQueueRealtimeEvent(() => applyPresenceDiff(payload)),
      onPresenceSync: (payload) => applyOrQueueRealtimeEvent(() => applyPresenceSync(payload)),
      onServerStatus: (payload) => applyOrQueueRealtimeEvent(() => applyServerStatus(payload)),
      onNotificationMention: (payload) => applyOrQueueRealtimeEvent(() => handleMentionNotification(payload)),
      onNotificationDirectMessage: (payload) => applyOrQueueRealtimeEvent(() => handleMentionNotification(payload)),
      onNotificationPreference: (payload) => applyOrQueueRealtimeEvent(() => applyNotificationPreference(payload)),
    },
    onConnected: refreshAuthoritativeBootstrap,
    realtimeClientFactory,
    realtimeClientRef,
    sessionKey: currentUser && mode !== "landing" && bootstrapReady ? currentUser.id : null,
  })

  useEffect(() => {
    if (!("serviceWorker" in navigator)) return

    return synchronizeServiceWorkerClientLease({
      healthy: Boolean(
        currentUser &&
        mode !== "landing" &&
        bootstrapReady &&
        connectionHealth === "connected" &&
        pushConfig.session_generation
      ),
      sessionGeneration: pushConfig.session_generation || null,
    })
  }, [
    bootstrapReady,
    connectionHealth,
    currentUser?.id,
    mode,
    pushConfig.session_generation,
  ])

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
    setComposerError(null)
  }, [activeChannelId, activeServerId, view])

  useEffect(() => {
    if (!currentUser || mode === "landing") return

    const bufferId = view === "chat" ? activeChannelId : view === "server" ? activeServerId : null
    if (bufferId) saveActiveBufferPreference(currentUser.id, bufferId)
  }, [activeChannelId, activeServerId, currentUser?.id, mode, view])

  useEffect(() => {
    notificationDeviceStateRef.current = notificationDeviceState
  }, [notificationDeviceState])

  useEffect(() => {
    pushConfigRef.current = pushConfig
  }, [pushConfig])

  useEffect(() => {
    if (!currentUser || mode === "landing" || !pushConfig.configured) return

    const refresh = () => {
      refreshNotificationDevice(pushConfig)
    }

    window.addEventListener("focus", refresh)
    return () => window.removeEventListener("focus", refresh)
  }, [
    apiClient,
    currentUser?.id,
    mode,
    pushConfig.configured,
    pushConfig.session_generation,
    pushConfig.session_installation_id,
    pushConfig.session_registration_confirmed,
    pushConfig.vapid_public_key,
  ])

  useEffect(() => {
    if (!("serviceWorker" in navigator)) return
    const serviceWorker = navigator.serviceWorker

    const navigateFromNotification = (event: MessageEvent) => {
      if (event.data?.type !== "notification:navigate" || !event.data.bufferId) return
      selectBuffer(event.data.bufferId)
    }

    serviceWorker.addEventListener("message", navigateFromNotification)
    return () => serviceWorker.removeEventListener("message", navigateFromNotification)
  }, [])

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
    if (!currentUser || mode === "landing") {
      setBootstrapLoading(false)
      setBootstrapReady(false)
      return
    }

    let active = true
    setBootstrapLoading(true)
    setBootstrapReady(false)

    apiClient
      .bootstrap()
      .then((bootstrap) => {
        if (active) applyBootstrap(bootstrap)
      })
      .catch(() => {})
      .finally(() => {
        if (active) {
          setBootstrapLoading(false)
          setBootstrapReady(true)
        }
      })

    return () => {
      active = false
    }
  }, [apiClient, currentUser?.id, mode])

  useEffect(() => {
    if (mode === "landing" || view !== "discover" || discoverRequestedRef.current) return

    discoverRequestedRef.current = true
    setDiscoverLoading(true)
    setDiscoverError(null)

    apiClient
      .discoveryServerChannels()
      .then(({server_channels}) => setDiscoverServerChannels(server_channels || []))
      .catch(() => setDiscoverError("The IRC directory could not be loaded. Try again later."))
      .finally(() => setDiscoverLoading(false))
  }, [apiClient, mode, view])

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
    if (
      mode === "landing" ||
      view !== "chat" ||
      !activeChannel ||
      !["channel:", "direct:"].some((prefix) => activeChannel.id.startsWith(prefix))
    ) return
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
        const reply = await realtimeClientRef.current.push<{
          buffer?: BufferRecord
          directory?: ChannelDirectory
          message?: ChatMessage
          revision?: number
        }>("command:run", {
          command_id: commandId,
          input: body,
          buffer_id: bufferId,
        })

        setDraft("")
        if (reply.buffer?.buffer_type === "direct_message") {
          openDirectMessage(reply.buffer, reply.revision, reply.message)
        }
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

    if (
      realtimeClientRef.current &&
      (activeChannel.id?.startsWith("channel:") || activeChannel.id?.startsWith("direct:"))
    ) {
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

  async function joinDiscoveredServerChannel(serverChannel: ServerChannel): Promise<void> {
    setJoiningDiscoveryServerChannelId(serverChannel.id)
    setDiscoverError(null)

    try {
      const joined = await apiClient.joinDiscoveryServerChannel(serverChannel.id)
      applyAuthoritativeJoinedTopic(joined)
    } catch (_error) {
      setDiscoverError(`Could not join ${serverChannel.name} on ${serverChannel.network_name}.`)
    } finally {
      setJoiningDiscoveryServerChannelId(null)
    }
  }

  async function joinThisServerChannel(channel: string): Promise<void> {
    if (!activeServer?.server_connection_id) return
    setDiscoverError(null)

    try {
      const joined = await apiClient.joinChannel(activeServer.server_connection_id, channel)
      applyJoinedChannel({...activeServer, id: activeServer.server_connection_id}, joined.channel)
    } catch (_error) {
      setDiscoverError(`Could not join ${channel} on ${activeServer.name || activeServer.host}.`)
    }
  }

  function currentBufferId(): string | undefined {
    if (view === "server" && activeServer) return activeServer.id
    return activeChannel?.id
  }

  async function enableNotificationsOnDevice(): Promise<boolean> {
    if (!currentUser) return false
    const operationId = ++notificationOperationIdRef.current
    const sessionGeneration = pushConfig.session_generation || null
    applyNotificationDeviceState({...notificationDeviceStateRef.current, loading: true, error: null})
    const next = await enableNotificationDevice(apiClient, pushConfig, currentUser.id)

    const currentOperation =
      operationId === notificationOperationIdRef.current &&
      (pushConfigRef.current.session_generation || null) === sessionGeneration

    if (currentOperation) applyNotificationDeviceState(next)
    return currentOperation && next.subscribed
  }

  async function toggleServerNotifications(server: ServerConnection): Promise<void> {
    const control = notificationControlState(
      notificationDeviceStateRef.current,
      server.mention_notifications_enabled
    )
    if (control.kind === "unavailable") return

    if (!notificationDeviceStateRef.current.subscribed) {
      if (!await enableNotificationsOnDevice()) return
      if (server.mention_notifications_enabled) return
    }

    await saveServerNotificationPreference(server, !server.mention_notifications_enabled)
  }

  async function toggleChannelNotifications(channel: Channel): Promise<void> {
    if (channel.buffer_type !== "channel") return
    const server = channel.connection || activeServer
    if (!server) return

    const control = notificationControlState(
      notificationDeviceStateRef.current,
      channel.mention_notifications_enabled,
      server.mention_notifications_enabled,
      server.name || server.host
    )
    if (control.kind === "unavailable") return

    if (!notificationDeviceStateRef.current.subscribed) {
      if (!await enableNotificationsOnDevice()) return
      if (!server.mention_notifications_enabled) {
        await saveServerNotificationPreference(server, true)
      }
      if (!channel.mention_notifications_enabled) {
        await saveChannelNotificationPreference(channel, true)
      }
      return
    }

    if (!server.mention_notifications_enabled) {
      await saveServerNotificationPreference(server, true)
      if (!channel.mention_notifications_enabled) {
        await saveChannelNotificationPreference(channel, true)
      }
      return
    }

    await saveChannelNotificationPreference(channel, !channel.mention_notifications_enabled)
  }

  async function saveServerNotificationPreference(server: ServerConnection, enabled: boolean): Promise<void> {
    const previous = server.mention_notifications_enabled
    const revision = server.notification_preference_revision
    const operation = beginNotificationPreferenceOperation("server", server.server_connection_id, revision, previous)
    setNotificationSaving(server.id, true)
    applyOptimisticNotificationPreference("server", server.server_connection_id, enabled)

    try {
      const {preference} = await apiClient.updateServerNotificationPreference(server.server_connection_id, enabled)
      applyNotificationPreference(preference)
    } catch (_error) {
      rollbackNotificationPreference("server", server.server_connection_id, operation)
    } finally {
      setNotificationSaving(server.id, false)
    }
  }

  async function saveChannelNotificationPreference(channel: Channel, enabled: boolean): Promise<void> {
    if (channel.buffer_type !== "channel") return
    const previous = channel.mention_notifications_enabled
    const revision = channel.notification_preference_revision
    const operation = beginNotificationPreferenceOperation("channel", channel.channel_membership_id, revision, previous)
    setNotificationSaving(channel.id, true)
    applyOptimisticNotificationPreference("channel", channel.channel_membership_id, enabled)

    try {
      const {preference} = await apiClient.updateChannelNotificationPreference(channel.channel_membership_id, enabled)
      applyNotificationPreference(preference)
    } catch (_error) {
      rollbackNotificationPreference("channel", channel.channel_membership_id, operation)
    } finally {
      setNotificationSaving(channel.id, false)
    }
  }

  function setNotificationSaving(id: string, saving: boolean): void {
    setNotificationSavingIds((current) => {
      const next = new Set(current)
      if (saving) next.add(id)
      else next.delete(id)
      return next
    })
  }

  function applyNotificationPreference(payload: NotificationPreferencePayload): void {
    if (
      !["server", "channel"].includes(payload.scope) ||
      !validProtocolEntityId(payload.id) ||
      typeof payload.mention_notifications_enabled !== "boolean" ||
      !Number.isSafeInteger(payload.revision) ||
      payload.revision < 0
    ) return

    setConnections((current) => current.map((server) => {
      if (payload.scope === "server" && String(server.server_connection_id) === String(payload.id)) {
        if (payload.revision <= server.notification_preference_revision) return server

        notificationPreferenceOperationsRef.current.delete(notificationPreferenceKey("server", payload.id))

        return {
          ...server,
          mention_notifications_enabled: payload.mention_notifications_enabled,
          notification_preference_revision: payload.revision,
        }
      }

      if (payload.scope !== "channel") return server

      return {
        ...server,
        channels: server.channels.map((channel) =>
          {
            if (channel.buffer_type !== "channel") return channel
            if (String(channel.channel_membership_id) !== String(payload.id)) return channel
            if (payload.revision <= channel.notification_preference_revision) return channel

            notificationPreferenceOperationsRef.current.delete(notificationPreferenceKey("channel", payload.id))

            return {
              ...channel,
              mention_notifications_enabled: payload.mention_notifications_enabled,
              notification_preference_revision: payload.revision,
            }
          }
        ),
      }
    }))
  }

  function applyOptimisticNotificationPreference(
    scope: "server" | "channel",
    id: EntityId,
    enabled: boolean
  ): void {
    setConnections((current) => current.map((server) => {
      if (scope === "server" && String(server.server_connection_id) === String(id)) {
        return {...server, mention_notifications_enabled: enabled}
      }

      if (scope !== "channel") return server

      return {
        ...server,
        channels: server.channels.map((channel) =>
          channel.buffer_type === "channel" &&
          String(channel.channel_membership_id) === String(id)
            ? {...channel, mention_notifications_enabled: enabled}
            : channel
        ),
      }
    }))
  }

  function beginNotificationPreferenceOperation(
    scope: "server" | "channel",
    id: EntityId,
    baseRevision: number,
    previous: boolean
  ): NotificationPreferenceOperation {
    const operation = {
      baseRevision,
      epoch: ++notificationPreferenceEpochRef.current,
      previous,
    }
    notificationPreferenceOperationsRef.current.set(notificationPreferenceKey(scope, id), operation)
    return operation
  }

  function rollbackNotificationPreference(
    scope: "server" | "channel",
    id: EntityId,
    operation: NotificationPreferenceOperation
  ): void {
    const key = notificationPreferenceKey(scope, id)
    if (notificationPreferenceOperationsRef.current.get(key)?.epoch !== operation.epoch) return

    notificationPreferenceOperationsRef.current.delete(key)
    setConnections((current) => current.map((server) => {
      if (
        scope === "server" &&
        String(server.server_connection_id) === String(id) &&
        server.notification_preference_revision === operation.baseRevision
      ) {
        return {...server, mention_notifications_enabled: operation.previous}
      }

      if (scope !== "channel") return server

      return {
        ...server,
        channels: server.channels.map((channel) =>
          String(channel.channel_membership_id) === String(id) &&
          channel.notification_preference_revision === operation.baseRevision
            ? {...channel, mention_notifications_enabled: operation.previous}
            : channel
        ),
      }
    }))
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

  async function handleMentionNotification(message: NotificationEventPayload): Promise<void> {
    if (!validNotificationEvent(message)) return

    if (notificationDeviceStateRef.current.loading) {
      queuedNotificationEventsRef.current.push(message)
      if (queuedNotificationEventsRef.current.length > 100) {
        queuedNotificationEventsRef.current.shift()
      }
      return
    }

    const notificationUser = currentUserRef.current
    if (!notificationUser) return

    if (notificationDeliveryCoveredByPush(
      notificationDeviceStateRef.current,
      notificationUser.id,
      pushConfigRef.current
    )) return

    const server = connectionsRef.current.find(
      (connection) =>
        String(connection.server_connection_id) === String(message.server_connection_id)
    )
    if (!server) return

    const buffer = server.channels.find((channel) => channel.id === message.buffer_id)
    if (!buffer || buffer.blocked) return

    if (
      buffer.buffer_type !== "direct_message" &&
      (!server.mention_notifications_enabled || !buffer.mention_notifications_enabled)
    ) return

    const coordinator = notificationEventCoordinatorRef.current
    if (!coordinator) return

    const visible = document.visibilityState !== "hidden"
    if (visible) {
      await coordinator.coordinate(message.event_id, {
        eligible: false,
        visible: true,
        display: () => false,
      })
      return
    }

    const userId = currentUserRef.current?.id
    const sessionGeneration = pushConfigRef.current.session_generation
    if (!userId || !sessionGeneration) return

    const authorizationEpoch = notificationAuthorizationEpochRef.current
    const controller = new AbortController()
    notificationEligibilityControllersRef.current.add(controller)

    let eligible = false
    try {
      const result = await apiClient.notificationEligibility(
        message.notification_id,
        sessionGeneration,
        controller.signal
      )
      eligible = result.eligible
    } catch (_error) {
      return
    } finally {
      notificationEligibilityControllersRef.current.delete(controller)
    }

    if (
      !eligible ||
      controller.signal.aborted ||
      authorizationEpoch !== notificationAuthorizationEpochRef.current ||
      String(currentUserRef.current?.id) !== String(userId) ||
      pushConfigRef.current.session_generation !== sessionGeneration ||
      notificationEventCoordinatorRef.current !== coordinator ||
      document.visibilityState !== "hidden" ||
      notificationDeliveryCoveredByPush(
        notificationDeviceStateRef.current,
        userId,
        pushConfigRef.current
      )
    ) return

    await coordinator.coordinate(message.event_id, {
      eligible: true,
      visible: false,
      display: () => {
        if (
          controller.signal.aborted ||
          authorizationEpoch !== notificationAuthorizationEpochRef.current ||
          String(currentUserRef.current?.id) !== String(userId) ||
          pushConfigRef.current.session_generation !== sessionGeneration ||
          notificationEventCoordinatorRef.current !== coordinator ||
          document.visibilityState !== "hidden" ||
          notificationDeliveryCoveredByPush(
            notificationDeviceStateRef.current,
            userId,
            pushConfigRef.current
          ) ||
          !mentionNotificationEligible(message, {
            notificationState: notificationDeviceStateRef.current.capability,
          })
        ) return false

        return showMentionNotification(message, {
          notificationState: notificationDeviceStateRef.current.capability,
        })
      },
    })
  }

  function abortNotificationEligibilityChecks(): void {
    notificationEligibilityControllersRef.current.forEach((controller) => controller.abort())
    notificationEligibilityControllersRef.current.clear()
  }

  function applyNotificationDeviceState(next: NotificationDeviceState): void {
    const previous = notificationDeviceStateRef.current
    if (
      previous.capability !== next.capability ||
      previous.configured !== next.configured ||
      previous.loading !== next.loading ||
      previous.subscribed !== next.subscribed
    ) {
      notificationAuthorizationEpochRef.current += 1
      abortNotificationEligibilityChecks()
    }

    notificationDeviceStateRef.current = next
    setNotificationDeviceState(next)

    if (next.loading || queuedNotificationEventsRef.current.length === 0) return

    const queued = queuedNotificationEventsRef.current.splice(0)
    queued.forEach(handleMentionNotification)
  }

  function refreshNotificationDevice(authoritativePush: PushConfig): void {
    if (!currentUser) return

    const operationId = ++notificationOperationIdRef.current
    const sessionGeneration = authoritativePush.session_generation || null
    applyNotificationDeviceState({...notificationDeviceStateRef.current, loading: true, error: null})

    synchronizeNotificationDevice(apiClient, authoritativePush, currentUser.id).then((next) => {
      if (
        operationId === notificationOperationIdRef.current &&
        (pushConfigRef.current.session_generation || null) === sessionGeneration
      ) {
        applyNotificationDeviceState(next)
      }
    })
  }

  function applyBootstrap(bootstrap: BootstrapPayload, preserveSelection = false): void {
    const state = buildBootstrapState(bootstrap)
    if (!state) return

    const preferredBuffer = selectPreferredBuffer(
      state.connections,
      (preserveSelection ? currentBufferId() : requestedBufferIdRef.current) ||
        (currentUser && loadActiveBufferPreference(currentUser.id))
    )

    requestedBufferIdRef.current = null
    if (preferredBuffer && window.history?.replaceState && new URLSearchParams(window.location.search).has("buffer")) {
      window.history.replaceState(null, "", window.location.pathname)
    }

    if (state.topics) setTopics(state.topics)
    setCommandCatalog(state.commandCatalog)
    applyPushConfig(state.push)
    applyNotificationDeviceState({
      ...notificationDeviceStateRef.current,
      configured: state.push.configured,
      loading: true,
    })
    if (currentUser) {
      refreshNotificationDevice(state.push)
    }
    seedDirectMessageTombstones(state.directMessageTombstones)
    setConnections(state.connections)
    connectionsRef.current = state.connections
    replaceBootstrapMessages(state.messagesByChannel, state.messagesByServer)
    setUsersByChannel(state.usersByChannel)
    if (preferredBuffer) {
      setActiveChannelId(preferredBuffer.activeChannelId)
      setActiveServerId(preferredBuffer.activeServerId)
      setView(preferredBuffer.view)
    } else {
      if (state.activeChannelId) setActiveChannelId(state.activeChannelId)
      if (state.activeServerId) setActiveServerId(state.activeServerId)
      if (state.view) setView(state.view)
    }
    if (!preserveSelection) reconcileBootstrapCursors(state.cursorsByBuffer)
  }

  function applyPushConfig(next: PushConfig): void {
    const previous = pushConfigRef.current
    if (
      previous.configured !== next.configured ||
      previous.session_generation !== next.session_generation ||
      previous.session_installation_id !== next.session_installation_id ||
      previous.session_registration_confirmed !== next.session_registration_confirmed ||
      previous.vapid_public_key !== next.vapid_public_key
    ) {
      notificationAuthorizationEpochRef.current += 1
      abortNotificationEligibilityChecks()
    }

    pushConfigRef.current = next
    setPushConfig(next)
  }

  function applyOrQueueRealtimeEvent(callback: () => void): void {
    if (realtimeRefreshInFlightRef.current) {
      queuedRealtimeEventsRef.current.push(callback)
    } else {
      callback()
    }
  }

  function refreshAuthoritativeBootstrap(): void {
    if (realtimeRefreshInFlightRef.current) {
      realtimeRefreshRequestedRef.current = true
      return
    }

    realtimeRefreshInFlightRef.current = true
    apiClient
      .bootstrap()
      .then((bootstrap) => {
        applyBootstrap(bootstrap, true)
        return reconcileAllBuffers()
      })
      .catch(() => reconcileAllBuffers())
      .finally(() => {
        realtimeRefreshInFlightRef.current = false

        if (realtimeRefreshRequestedRef.current) {
          realtimeRefreshRequestedRef.current = false
          refreshAuthoritativeBootstrap()
          return
        }

        const queuedEvents = queuedRealtimeEventsRef.current.splice(0)
        queuedEvents.forEach((callback) => callback())
      })
  }

  function selectBuffer(bufferId: string): void {
    const selected = selectPreferredBuffer(connectionsRef.current, bufferId)
    if (!selected) return

    activeChannelIdRef.current = selected.activeChannelId
    activeServerIdRef.current = selected.activeServerId
    viewRef.current = selected.view
    setActiveChannelId(selected.activeChannelId)
    setActiveServerId(selected.activeServerId)
    setView(selected.view)
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
      discoverServerChannels={discoverServerChannels}
      discoverError={discoverError}
      discoverLoading={discoverLoading}
      draft={draft}
      joiningDiscoveryServerChannelId={joiningDiscoveryServerChannelId}
      messages={messages}
      messagesLoading={bootstrapLoading}
      notificationDeviceState={notificationDeviceState}
      notificationSavingIds={notificationSavingIds}
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
      onJoinDiscoverServerChannel={joinDiscoveredServerChannel}
      onJoinThisServerChannel={joinThisServerChannel}
      onJoinManualServer={joinManualServer}
      onLeaveChannel={leaveChannel}
      onCloseDirectMessage={closeDirectMessage}
      onMarkChannelRead={markChannelRead}
      onToggleChannelNotifications={toggleChannelNotifications}
      onSetDirectMessageBlocked={setDirectMessageBlocked}
      onToggleServerNotifications={toggleServerNotifications}
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

  function openDirectMessage(
    buffer: DirectMessageBufferRecord,
    revision: number | undefined,
    message?: ChatMessage
  ): void {
    const server = connectionsRef.current.find(
      (connection) => String(connection.server_connection_id) === String(buffer.server_connection_id)
    )
    if (!server) return

    const backendConnection: BackendConnection = {
      id: server.server_connection_id,
      name: server.name,
      host: server.host,
      port: server.port,
      use_tls: server.use_tls,
      nickname: server.nickname,
      status: server.status,
      mention_notifications_enabled: server.mention_notifications_enabled,
      notification_preference_revision: server.notification_preference_revision,
    }

    if (typeof revision !== "number" || !Number.isSafeInteger(revision)) return
    if (revision !== buffer.direct_message_revision) return
    applyDirectMessageThread({connection: backendConnection, buffer, revision})
    if (message) {
      setMessagesByChannel((current) => ({
        ...current,
        [buffer.buffer_id]: [
          ...(current[buffer.buffer_id] || []),
          normalizeMessage(message),
        ],
      }))
    }
    activeChannelIdRef.current = buffer.buffer_id
    activeServerIdRef.current = server.id
    viewRef.current = "chat"
    setActiveChannelId(buffer.buffer_id)
    setActiveServerId(server.id)
    setView("chat")
  }

  async function markBufferRead(bufferId?: string | null): Promise<void> {
    if (!bufferId || !realtimeClientRef.current) return

    try {
      if (bufferId.startsWith("direct:")) {
        const payload = await realtimeClientRef.current.push<DirectMessageThreadPayload>(
          "buffer:read",
          {buffer_id: bufferId}
        )
        applyDirectMessageThread(payload)
      } else {
        const payload = await realtimeClientRef.current.push<BufferReadPayload>("buffer:read", {
          buffer_id: bufferId,
        })
        applyBufferRead(payload)
      }
    } catch (_error) {
      // Keep counters as-is if the backend rejects the read marker.
    }
  }

}
