import {normalizeMessage, normalizeTopic} from "./chat_store.js"

export function buildBootstrapState(bootstrap) {
  if (!bootstrap?.buffers || !bootstrap?.connections) return null

  const connections = bootstrap.connections.map((connection) => {
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

  const messagesByServer = Object.fromEntries(
    connections.map((connection) => [
      connection.id,
      (bootstrap.messages_by_buffer || {})[connection.id]?.map(normalizeMessage) || [],
    ])
  )
  const messagesByChannel = Object.fromEntries(
    Object.entries(bootstrap.messages_by_buffer || {}).map(([bufferId, messages]) => [
      bufferId,
      messages.map(normalizeMessage),
    ])
  )

  let activeChannelId = null
  let activeServerId = null
  let view = null

  if (bootstrap.active_buffer_id?.startsWith("channel:")) {
    activeChannelId = bootstrap.active_buffer_id
    activeServerId = connections.find((connection) =>
      connection.channels.some((channel) => channel.id === activeChannelId)
    )?.id || null
  } else if (bootstrap.active_buffer_id?.startsWith("server:")) {
    activeServerId = bootstrap.active_buffer_id
    view = "server"
  }

  return {
    activeChannelId,
    activeServerId,
    commandCatalog: bootstrap.command_catalog || [],
    connections,
    cursorsByBuffer: bootstrap.message_cursors_by_buffer || {},
    messagesByChannel,
    messagesByServer,
    notificationState: bootstrap.notification_state || null,
    topics: bootstrap.topics?.length ? bootstrap.topics.map(normalizeTopic) : null,
    usersByChannel: bootstrap.users_by_buffer || {},
    view,
  }
}
