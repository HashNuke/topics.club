import type {ActiveBufferSelection} from "./active_buffer_preference.ts"
import type {Channel, EntityId, ServerConnection} from "./types.ts"

export type ChatRoute =
  | {kind: "root"}
  | {kind: "buffer"; connectionId: string; target: string | null}
  | {kind: "directory"; connectionId: string; page: number; query: string}
  | {kind: "discover"; connectionId: string | null; page: number; query: string}

export function readChatRoute(location: Pick<Location, "pathname" | "search"> = window.location): ChatRoute {
  const segments = location.pathname.split("/").filter(Boolean)
  if (segments[0] !== "chat") return {kind: "root"}

  if (segments[1] === "discover") {
    const scope = segments[2]
    if (scope === "all") return {kind: "discover", connectionId: null, page: pageParam(location.search), query: queryParam(location.search)}
    if (validId(scope)) return {kind: "discover", connectionId: scope, page: pageParam(location.search), query: queryParam(location.search)}
    return {kind: "discover", connectionId: null, page: 1, query: ""}
  }

  if (!validId(segments[1])) return {kind: "root"}
  const target = decodeSegment(segments[2])

  if (target === "/list") {
    return {kind: "directory", connectionId: segments[1], page: pageParam(location.search), query: queryParam(location.search)}
  }

  return {kind: "buffer", connectionId: segments[1], target}
}

export function bufferPath(connectionId: EntityId, channel?: Pick<Channel, "channel"> | null): string {
  const base = `/chat/${encodeURIComponent(String(connectionId))}`
  return channel ? `${base}/${encodeURIComponent(channel.channel)}` : base
}

export function directoryPath(connectionId: EntityId, page = 1, query = ""): string {
  return withSearch(`/chat/${encodeURIComponent(String(connectionId))}/${encodeURIComponent("/list")}`, page, query)
}

export function discoverPath(connectionId: EntityId | null, page = 1, query = ""): string {
  return withSearch(`/chat/discover/${connectionId === null ? "all" : encodeURIComponent(String(connectionId))}`, page, query)
}

export function selectRouteBuffer(connections: ServerConnection[], route: ChatRoute): ActiveBufferSelection | null {
  if (route.kind !== "buffer") return null

  const server = connections.find((connection) => String(connection.server_connection_id) === route.connectionId)
  if (!server) return null
  if (!route.target) return {activeChannelId: null, activeServerId: server.id, view: "server"}

  const target = route.target.toLocaleLowerCase()
  const channel = server.channels.find((candidate) => candidate.channel.toLocaleLowerCase() === target)
  if (!channel) return null

  return {activeChannelId: channel.id, activeServerId: server.id, view: "chat"}
}

function withSearch(path: string, page: number, query: string): string {
  const search = new URLSearchParams()
  if (page > 1) search.set("p", String(page))
  if (query) search.set("q", query)
  const suffix = search.toString()
  return suffix ? `${path}?${suffix}` : path
}

function pageParam(search: string): number {
  const value = new URLSearchParams(search).get("p")
  if (!value || !/^[1-9][0-9]*$/.test(value)) return 1
  return Number(value)
}

function queryParam(search: string): string {
  return (new URLSearchParams(search).get("q") || "").trim().slice(0, 100)
}

function validId(value?: string): value is string {
  return Boolean(value && /^[1-9][0-9]*$/.test(value))
}

function decodeSegment(value?: string): string | null {
  if (!value) return null

  try {
    return decodeURIComponent(value)
  } catch (_error) {
    return null
  }
}
