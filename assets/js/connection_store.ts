import type {
  BackendConnection,
  BufferReadPayload,
  BufferRecord,
  Channel,
  ChannelMembership,
  ServerConnection,
  ServerStatusPayload,
  Topic,
} from "./types.ts"

export function channelFromBuffer(buffer: BufferRecord, topic?: {description?: string}): Channel {
  return {
    id: buffer.buffer_id,
    channel_membership_id: buffer.channel_membership_id,
    channel: buffer.title,
    topic: topic?.description || buffer.subtitle,
    unread_count: buffer.unread_count,
    mention_count: buffer.mention_count,
    mention_notifications_enabled: buffer.mention_notifications_enabled ?? true,
  }
}

export function channelFromMembership(membership: ChannelMembership, host: string): Channel {
  return {
    id: `channel:${membership.id}`,
    channel_membership_id: membership.id,
    channel: membership.channel,
    topic: `on ${host}`,
    unread_count: membership.unread_count,
    mention_count: membership.mention_count,
    mention_notifications_enabled: membership.mention_notifications_enabled ?? true,
  }
}

export function upsertJoinedChannel(
  connections: ServerConnection[],
  connection: BackendConnection,
  channel: Channel,
  {updateStatus = false}: {updateStatus?: boolean} = {}
): ServerConnection[] {
  const connectionId = `server:${connection.id}`
  const existingConnection = connections.find(
    (item) => item.server_connection_id === connection.id || item.id === connectionId
  )

  if (existingConnection) {
    return connections.map((item) => {
      if (item.id !== existingConnection.id) return item

      return {
        ...item,
        ...(updateStatus ? {status: connection.status} : {}),
        channels: item.channels.some((existing) => existing.id === channel.id)
          ? item.channels
          : [...item.channels, channel],
      }
    })
  }

  return [
    ...connections,
    {
      id: connectionId,
      server_connection_id: connection.id,
      name: connection.name,
      host: connection.host,
      port: connection.port,
      use_tls: connection.use_tls,
      nickname: connection.nickname,
      status: connection.status,
      mention_notifications_enabled: connection.mention_notifications_enabled ?? true,
      channels: [channel],
    },
  ]
}

export function updateServerStatus(
  connections: ServerConnection[],
  payload: ServerStatusPayload
): ServerConnection[] {
  return connections.map((connection) =>
    connection.server_connection_id === payload.server_connection_id
      ? {...connection, status: payload.status, nickname: payload.nickname || connection.nickname}
      : connection
  )
}

export function updateBufferRead(connections: ServerConnection[], payload: BufferReadPayload): ServerConnection[] {
  return connections.map((connection) => {
    if (connection.id === payload.buffer_id) {
      return {
        ...connection,
        unread_count: payload.unread_count ?? 0,
        mention_count: payload.mention_count ?? 0,
      }
    }

    return {
      ...connection,
      channels: connection.channels.map((channel) =>
        channel.id === payload.buffer_id
          ? {
              ...channel,
              unread_count: payload.unread_count ?? 0,
              mention_count: payload.mention_count ?? 0,
            }
          : channel
      ),
    }
  })
}

export function removeChannel(connections: ServerConnection[], channelId: string): ServerConnection[] {
  return connections.map((connection) => ({
    ...connection,
    channels: connection.channels.filter((channel) => channel.id !== channelId),
  }))
}

export function updateConnectionDetails(
  connections: ServerConnection[],
  updated: BackendConnection
): ServerConnection[] {
  return connections.map((server) =>
    server.server_connection_id === updated.id
      ? {
          ...server,
          name: updated.name,
          host: updated.host,
          port: updated.port,
          use_tls: updated.use_tls,
          nickname: updated.nickname,
          status: updated.status,
          channels: server.channels.map((channel) => ({
            ...channel,
            topic: channel.topic === `on ${server.host}` ? `on ${updated.host}` : channel.topic,
          })),
        }
      : server
  )
}

export function planServerRemoval(connections: ServerConnection[], serverConnectionId: string | number) {
  const deletedId = `server:${serverConnectionId}`
  const deletedServer = connections.find(
    (server) => server.id === deletedId || server.server_connection_id === serverConnectionId
  )
  if (!deletedServer) return null

  const nextConnections = connections.filter((server) => server.id !== deletedServer.id)
  const nextServer = nextConnections[0]

  return {
    deletedChannelIds: new Set(deletedServer.channels.map((channel) => channel.id)),
    deletedServer,
    nextChannel: nextServer?.channels[0],
    nextConnections,
    nextServer,
  }
}
