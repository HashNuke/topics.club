import type {
  BackendConnection,
  BufferRecord,
  ChatMessage,
  ChatUser,
  ConnectionHealth,
  MessagesByBuffer,
  PresenceDiff,
  Topic,
  TopicInput,
  UsersByBuffer,
} from "./types.ts"

interface UnreadCounts {
  unread_count: number
  mention_count: number
}

export interface ChatState {
  connections: BackendConnection[]
  buffers: BufferRecord[]
  activeBufferId: string | null
  messagesByBuffer: MessagesByBuffer
  usersByBuffer: UsersByBuffer
  unreadByBuffer: Record<string, UnreadCounts>
  connectionHealth: ConnectionHealth
}

interface BootstrapPayload {
  connections?: BackendConnection[]
  buffers?: BufferRecord[]
  active_buffer_id?: string | null
  messages_by_buffer?: MessagesByBuffer
  users_by_buffer?: UsersByBuffer
}

type ChatAction =
  | {type: "bootstrap:loaded"; bootstrap: BootstrapPayload}
  | {type: "buffer:message"; message: ChatMessage}
  | {type: "buffer:read"; buffer_id: string}
  | {type: "presence:sync"; buffer_id: string; users?: ChatUser[]}
  | {type: "presence:diff"; buffer_id: string; diff?: PresenceDiff}
  | {type: "server:status"; server_connection_id: string | number; status: string}
  | {type: "connection:health"; status: ConnectionHealth}

export const emptyChatState: ChatState = {
  connections: [],
  buffers: [],
  activeBufferId: null,
  messagesByBuffer: {},
  usersByBuffer: {},
  unreadByBuffer: {},
  connectionHealth: "disconnected",
}

export const MESSAGE_RENDER_LIMIT = 400

export function chatReducer(state: ChatState = emptyChatState, action: ChatAction): ChatState {
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

export function hydrateBootstrap(bootstrap: BootstrapPayload): ChatState {
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
  }
}

function appendBufferMessage(state: ChatState, message: ChatMessage): ChatState {
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

function markBufferRead(state: ChatState, bufferId: string): ChatState {
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

function applyServerStatus(
  state: ChatState,
  action: {server_connection_id: string | number; status: string}
): ChatState {
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

export function applyUserDiff(users: ChatUser[], diff?: PresenceDiff): ChatUser[] {
  if (!diff) return users

  if (diff.action === "join" && diff.user?.nick) {
    const joinedUser = diff.user
    if (users.some((user) => user.nick === joinedUser.nick)) return users
    return [...users, joinedUser]
  }

  if ((diff.action === "part" || diff.action === "quit") && diff.nick) {
    return users.filter((user) => user.nick !== diff.nick)
  }

  if (diff.action === "nick" && diff.old_nick && diff.new_nick) {
    const {old_nick: oldNick, new_nick: newNick} = diff
    return users.map((user) => (user.nick === oldNick ? {...user, nick: newNick} : user))
  }

  if (diff.action === "away" && diff.nick && diff.status) {
    return users.map((user) => (user.nick === diff.nick ? {...user, status: diff.status} : user))
  }

  if (diff.action === "role" && diff.nick && diff.role) {
    return users.map((user) => (user.nick === diff.nick ? {...user, role: diff.role} : user))
  }

  return users
}

export function normalizeTopic(topic: TopicInput): Topic {
  const channel = normalizeChannel(topic.channel || topic.name)
  return {
    ...topic,
    id: topic.id || `${topic.server_host}-${topic.channel || topic.name}`,
    channel,
    name: channel,
    description: topic.description || "A live topic you can join.",
    members: topic.members || topic.member_count,
    vibe: topic.vibe || "topic",
  }
}

export function normalizeMessage(message: ChatMessage): ChatMessage {
  return {
    ...message,
    occurredAt: message.occurredAt || message.occurred_at,
  }
}

export function trimMessagesToLimit(messages: ChatMessage[], limit = MESSAGE_RENDER_LIMIT): ChatMessage[] {
  if (messages.length <= limit) return messages
  return messages.slice(-limit)
}

export function appendTimelineMessage(
  messages: ChatMessage[],
  message: ChatMessage,
  readingOlder: boolean,
  limit = MESSAGE_RENDER_LIMIT
): ChatMessage[] {
  if (message.id && messages.some((current) => current.id === message.id)) {
    return messages.map((current) => (current.id === message.id ? {...current, ...message} : current))
  }

  const nextMessages = sortTimelineMessages([...messages, message])
  return readingOlder ? nextMessages : trimMessagesToLimit(nextMessages, limit)
}

export function mergeOlderMessages(olderMessages: ChatMessage[], currentMessages: ChatMessage[]): ChatMessage[] {
  const olderById = new Map(
    olderMessages.filter((message) => message.id != null).map((message) => [message.id, message])
  )
  const currentIds = new Set(currentMessages.map((message) => message.id))
  const updatedCurrent = currentMessages.map((message) => {
    const older = olderById.get(message.id)
    if (!older || commandStatusRank(older) < commandStatusRank(message)) return message
    return {...message, ...older}
  })
  const prepended = olderMessages.filter((message) => message.id == null || !currentIds.has(message.id))
  return sortTimelineMessages([...prepended, ...updatedCurrent])
}

export function mergeNewerMessages(currentMessages: ChatMessage[], newerMessages: ChatMessage[]): ChatMessage[] {
  const updatesById = new Map(
    newerMessages
      .filter((message) => message.id != null)
      .map((message) => [message.id, message])
  )
  const currentIds = new Set(currentMessages.map((message) => message.id))
  const updatedCurrent = currentMessages.map((message) => {
    if (!updatesById.has(message.id)) return message

    const update = updatesById.get(message.id)
    return commandStatusRank(update) < commandStatusRank(message) ? message : {...message, ...update}
  })
  const appended = newerMessages.filter((message) => message.id == null || !currentIds.has(message.id))

  return trimMessagesToLimit(sortTimelineMessages([...updatedCurrent, ...appended]))
}

function commandStatusRank(message?: ChatMessage): number {
  if (message?.kind !== "command") return 0

  const ranks: Record<string, number> = {
    sent: 1,
    acknowledged: 2,
    completed: 3,
    failed: 3,
    timed_out: 3,
  }
  const status = message.metadata?.command_status
  return (status && ranks[status]) || 0
}

export function latestBackendMessageId(messages: ChatMessage[]): number {
  return messages.reduce((latest, message) => {
    const id = Number(message.id)
    if (!Number.isInteger(id)) return latest
    return Math.max(latest, id)
  }, 0)
}

function sortTimelineMessages(messages: ChatMessage[]): ChatMessage[] {
  return [...messages].sort((left, right) => {
    const timeDiff = Date.parse(left.occurredAt || left.occurred_at || "") - Date.parse(right.occurredAt || right.occurred_at || "")
    if (timeDiff !== 0 && Number.isFinite(timeDiff)) return timeDiff

    const leftId = Number(left.id)
    const rightId = Number(right.id)
    if (Number.isInteger(leftId) && Number.isInteger(rightId)) return leftId - rightId

    return 0
  })
}

export function normalizeChannel(channel?: string): string {
  if (!channel) return "#general"
  return /^[^A-Za-z0-9\s,:\u0000\u0007]/u.test(channel) ? channel : "#" + channel
}
