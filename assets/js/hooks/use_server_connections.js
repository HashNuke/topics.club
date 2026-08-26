import {useEffect, useRef, useState} from "react"
import {normalizeChannel, normalizeTopic} from "../chat_store.ts"
import {
  channelFromBuffer,
  channelFromMembership,
  planServerRemoval,
  removeChannel,
  updateBufferRead,
  updateConnectionDetails,
  updateServerStatus,
  upsertJoinedChannel,
} from "../connection_store.ts"
import {backendTopicFor, numericId} from "../topic_navigation.ts"

export default function useServerConnections({
  activeChannelIdRef,
  activeServerIdRef,
  apiClient,
  appendSystemMessage,
  canJoinTopics,
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
}) {
  const [connections, setConnections] = useState([])
  const rejectedBufferIdsRef = useRef(new Set())
  const joinRejectionVersionsRef = useRef(new Map())

  useEffect(() => {
    connectionsRef.current = connections
  }, [connections, connectionsRef])

  async function joinTopic(topic) {
    const normalized = normalizeTopic(topic)
    const backendTopic = backendTopicFor(normalized, topics)
    const topicId = numericId(normalized.id) || numericId(backendTopic?.id)
    if (!canJoinTopics || !topicId) return

    const rejectionVersions = new Map(joinRejectionVersionsRef.current)

    try {
      const joined = await apiClient.joinTopic(topicId)
      applyJoinedTopic(joined, false, rejectionVersions)
    } catch (_error) {
      // Keep discovery open when the backend rejects a topic join.
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
    setMessagesByChannel((current) => ({...current, [channel.id]: current[channel.id] || []}))
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

    setConnections((current) =>
      upsertJoinedChannel(current, connection, channel, {updateStatus: true})
    )
    setMessagesByChannel((current) => ({...current, [channel.id]: current[channel.id] || []}))
    setActiveServerId(connectionId)
    setActiveChannelId(channel.id)
    setView("chat")
    return true
  }

  function applyServerStatus(payload) {
    setConnections((current) => updateServerStatus(current, payload))
    if (payload.status === "connected") defer(() => reconcileServerBuffers(payload.server_connection_id))
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
    setMessagesByChannel((current) => omitKeys(current, [channelId]))
    setUsersByChannel((current) => omitKeys(current, [channelId]))

    if (activeChannelIdRef.current === channelId) {
      setActiveServerId(`server:${payload.server_connection_id}`)
      setView("server")
    }
  }

  function applyBufferRead(payload) {
    if (!payload?.buffer_id) return
    setConnections((current) => updateBufferRead(current, payload))
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
      if (connection?.id) setConnections((current) => updateConnectionDetails(current, connection))
    } catch (_error) {
      // Leave the current connection details visible if the backend rejects the edit.
    }
  }

  function applyServerDeleted(payload) {
    const removal = planServerRemoval(connectionsRef.current, payload.server_connection_id)
    if (!removal) return

    const {deletedChannelIds, deletedServer, nextChannel, nextConnections, nextServer} = removal
    connectionsRef.current = nextConnections
    setConnections(nextConnections)
    setMessagesByServer((current) => omitKeys(current, [deletedServer.id]))
    setMessagesByChannel((current) => omitKeys(current, deletedChannelIds))
    setUsersByChannel((current) => omitKeys(current, deletedChannelIds))

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

  return {
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
  }
}

function omitKeys(object, keys) {
  const next = {...object}
  for (const key of keys) delete next[key]
  return next
}

function defer(callback) {
  if (typeof queueMicrotask === "function") {
    queueMicrotask(callback)
    return
  }

  Promise.resolve().then(callback)
}
