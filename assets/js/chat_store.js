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
