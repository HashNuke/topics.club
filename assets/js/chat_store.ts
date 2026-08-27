import type {
  ChatMessage,
  ChatUser,
  PresenceDiff,
  Topic,
  TopicInput,
  TimelineMessage,
} from "./types.ts"
import {canonicalChatMessage} from "./protocol_payload.ts"

export const MESSAGE_RENDER_LIMIT = 400

export function applyUserDiff(users: ChatUser[], diff: PresenceDiff): ChatUser[] {
  switch (diff.action) {
    case "join": {
      const joinedUser = diff.user

      if (users.some((user) => user.nick_key === joinedUser.nick_key)) {
        return users.map((user) => (user.nick_key === joinedUser.nick_key ? joinedUser : user))
      }

      return [...users, joinedUser]
    }

    case "part":
    case "quit":
      return users.filter((user) => user.nick_key !== diff.nick_key)

    case "nick":
      return users.map((user) =>
        user.nick_key === diff.old_nick_key
          ? {...user, nick: diff.new_nick, nick_key: diff.new_nick_key}
          : user
      )

    case "away":
      return users.map((user) =>
        user.nick_key === diff.nick_key ? {...user, status: diff.status} : user
      )

    case "role":
      return users.map((user) =>
        user.nick_key === diff.nick_key ? {...user, role: diff.role} : user
      )
  }
}

export function normalizeTopic(topic: TopicInput): Topic {
  return {
    id: topic.id,
    channel: normalizeChannel(topic.channel),
    name: normalizeChannel(topic.name),
    description: topic.description,
    server_host: topic.server_host,
    server_port: topic.server_port,
    use_tls: topic.use_tls,
  }
}

export function normalizeMessage(message: ChatMessage): TimelineMessage {
  const canonical = canonicalChatMessage(message)
  if (!canonical) throw new Error("invalid canonical message")

  return {
    ...canonical,
    occurredAt: canonical.occurred_at,
  }
}

export function trimMessagesToLimit(messages: TimelineMessage[], limit = MESSAGE_RENDER_LIMIT): TimelineMessage[] {
  if (messages.length <= limit) return messages
  return messages.slice(-limit)
}

export function appendTimelineMessage(
  messages: TimelineMessage[],
  message: TimelineMessage,
  readingOlder: boolean,
  limit = MESSAGE_RENDER_LIMIT
): TimelineMessage[] {
  if (message.id && messages.some((current) => current.id === message.id)) {
    return messages.map((current) => (current.id === message.id ? {...current, ...message} : current))
  }

  const nextMessages = sortTimelineMessages([...messages, message])
  return readingOlder ? nextMessages : trimMessagesToLimit(nextMessages, limit)
}

export function mergeOlderMessages(olderMessages: TimelineMessage[], currentMessages: TimelineMessage[]): TimelineMessage[] {
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

export function mergeNewerMessages(currentMessages: TimelineMessage[], newerMessages: TimelineMessage[]): TimelineMessage[] {
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

function commandStatusRank(message?: TimelineMessage): number {
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

export function latestBackendMessageId(messages: TimelineMessage[]): number {
  return messages.reduce((latest, message) => {
    const id = Number(message.id)
    if (!Number.isInteger(id)) return latest
    return Math.max(latest, id)
  }, 0)
}

function sortTimelineMessages(messages: TimelineMessage[]): TimelineMessage[] {
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
