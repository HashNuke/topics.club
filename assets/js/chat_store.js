export const emptyChatState = {
  connections: [],
  buffers: [],
  activeBufferId: null,
  messagesByBuffer: {},
  usersByBuffer: {},
  unreadByBuffer: {},
  connectionHealth: "disconnected",
  notificationState: "default",
}

export const MESSAGE_RENDER_LIMIT = 400

export function chatReducer(state = emptyChatState, action) {
  switch (action.type) {
    case "bootstrap:loaded":
      return hydrateBootstrap(action.bootstrap)
    case "buffer:message":
      return appendBufferMessage(state, action.message)
    case "buffer:read":
      return markBufferRead(state, action.buffer_id)
    case "presence:sync":
      return {
        ...state,
        usersByBuffer: {...state.usersByBuffer, [action.buffer_id]: action.users || []},
      }
    case "presence:diff":
      return {
        ...state,
        usersByBuffer: {
          ...state.usersByBuffer,
          [action.buffer_id]: applyUserDiff(state.usersByBuffer[action.buffer_id] || [], action.diff),
        },
      }
    case "server:status":
      return applyServerStatus(state, action)
    case "connection:health":
      return {...state, connectionHealth: action.status}
    default:
      return state
  }
}

export function hydrateBootstrap(bootstrap) {
  const buffers = bootstrap.buffers || []

  return {
    connections: bootstrap.connections || [],
    buffers,
    activeBufferId: bootstrap.active_buffer_id || buffers[0]?.buffer_id || null,
    messagesByBuffer: bootstrap.messages_by_buffer || {},
    usersByBuffer: bootstrap.users_by_buffer || {},
    unreadByBuffer: Object.fromEntries(
      buffers.map((buffer) => [
        buffer.buffer_id,
        {unread_count: buffer.unread_count || 0, mention_count: buffer.mention_count || 0},
      ])
    ),
    connectionHealth: "connected",
    notificationState: bootstrap.notification_state || "default",
  }
}

function appendBufferMessage(state, message) {
  const bufferId = message.buffer_id
  if (!bufferId) return state

  const currentMessages = state.messagesByBuffer[bufferId] || []
  const currentCounts = state.unreadByBuffer[bufferId] || {unread_count: 0, mention_count: 0}
  const isActive = state.activeBufferId === bufferId
  const nextCounts = isActive
    ? currentCounts
    : {
        unread_count: currentCounts.unread_count + 1,
        mention_count: currentCounts.mention_count + (message.mentioned ? 1 : 0),
      }

  return {
    ...state,
    messagesByBuffer: {
      ...state.messagesByBuffer,
      [bufferId]: [...currentMessages, message],
    },
    unreadByBuffer: {
      ...state.unreadByBuffer,
      [bufferId]: nextCounts,
    },
  }
}

function markBufferRead(state, bufferId) {
  return {
    ...state,
    unreadByBuffer: {
      ...state.unreadByBuffer,
      [bufferId]: {unread_count: 0, mention_count: 0},
    },
    buffers: state.buffers.map((buffer) =>
      buffer.buffer_id === bufferId ? {...buffer, unread_count: 0, mention_count: 0} : buffer
    ),
  }
}

function applyServerStatus(state, action) {
  return {
    ...state,
    connections: state.connections.map((connection) =>
      connection.id === action.server_connection_id ? {...connection, status: action.status} : connection
    ),
    buffers: state.buffers.map((buffer) =>
      buffer.server_connection_id === action.server_connection_id ? {...buffer, status: action.status} : buffer
    ),
  }
}

export function applyUserDiff(users, diff) {
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

export function normalizeTopic(topic) {
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

export function normalizeMessage(message) {
  return {
    ...message,
    occurredAt: message.occurredAt || message.occurred_at,
  }
}

export function trimMessagesToLimit(messages, limit = MESSAGE_RENDER_LIMIT) {
  if (messages.length <= limit) return messages
  return messages.slice(-limit)
}

export function appendTimelineMessage(messages, message, readingOlder, limit = MESSAGE_RENDER_LIMIT) {
  if (message.id && messages.some((current) => current.id === message.id)) return messages

  const nextMessages = sortTimelineMessages([...messages, message])
  return readingOlder ? nextMessages : trimMessagesToLimit(nextMessages, limit)
}

export function mergeOlderMessages(olderMessages, currentMessages) {
  const currentIds = new Set(currentMessages.map((message) => message.id))
  return sortTimelineMessages([...olderMessages.filter((message) => !currentIds.has(message.id)), ...currentMessages])
}

export function mergeNewerMessages(currentMessages, newerMessages) {
  const currentIds = new Set(currentMessages.map((message) => message.id))
  return trimMessagesToLimit(sortTimelineMessages([...currentMessages, ...newerMessages.filter((message) => !currentIds.has(message.id))]))
}

export function latestBackendMessageId(messages) {
  return messages.reduce((latest, message) => {
    const id = Number(message.id)
    if (!Number.isInteger(id)) return latest
    return Math.max(latest, id)
  }, 0)
}

function sortTimelineMessages(messages) {
  return [...messages].sort((left, right) => {
    const timeDiff = Date.parse(left.occurredAt || left.occurred_at || 0) - Date.parse(right.occurredAt || right.occurred_at || 0)
    if (timeDiff !== 0 && Number.isFinite(timeDiff)) return timeDiff

    const leftId = Number(left.id)
    const rightId = Number(right.id)
    if (Number.isInteger(leftId) && Number.isInteger(rightId)) return leftId - rightId

    return 0
  })
}

export function normalizeChannel(channel) {
  if (!channel) return "#general"
  return channel.startsWith("#") ? channel : `#${channel}`
}
