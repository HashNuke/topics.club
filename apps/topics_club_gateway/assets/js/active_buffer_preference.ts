import type {AppView, ServerConnection} from "./types.ts"

export interface ActiveBufferSelection {
  activeChannelId: string | null
  activeServerId: string
  view: AppView
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
