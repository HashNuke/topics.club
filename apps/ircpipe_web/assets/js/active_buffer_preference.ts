import type {AppView, EntityId, ServerConnection} from "./types.ts"

const STORAGE_PREFIX = "ircpipe.active-buffer"

export interface ActiveBufferSelection {
  activeChannelId: string | null
  activeServerId: string
  view: AppView
}

export function loadActiveBufferPreference(userId: EntityId): string | null {
  try {
    return globalThis.localStorage?.getItem(storageKey(userId)) || null
  } catch (_error) {
    return null
  }
}

export function saveActiveBufferPreference(userId: EntityId, bufferId: string): void {
  try {
    globalThis.localStorage?.setItem(storageKey(userId), bufferId)
  } catch (_error) {
    // Browsers may deny storage in private or restricted contexts.
  }
}

export function requestedBufferId(): string | null {
  if (typeof window === "undefined") return null
  return new URLSearchParams(window.location.search).get("buffer")
}

export function selectPreferredBuffer(
  connections: ServerConnection[],
  bufferId?: string | null
): ActiveBufferSelection | null {
  if (!bufferId) return null

  const server = connections.find((connection) =>
    connection.id === bufferId || connection.channels.some((channel) => channel.id === bufferId)
  )
  if (!server) return null

  if (server.id === bufferId) {
    return {activeChannelId: null, activeServerId: server.id, view: "server"}
  }

  return {activeChannelId: bufferId, activeServerId: server.id, view: "chat"}
}

function storageKey(userId: EntityId): string {
  return `${STORAGE_PREFIX}.${userId}`
}
