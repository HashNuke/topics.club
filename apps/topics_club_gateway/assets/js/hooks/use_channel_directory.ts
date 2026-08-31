import {
  useRef,
  useState,
  type Dispatch,
  type MutableRefObject,
  type SetStateAction,
} from "react"
import {channelDirectoryError} from "../app_feedback.ts"
import type {ApiClient} from "../api_client.ts"
import type {CommandError} from "../app_feedback.ts"
import type {RealtimeClient} from "../realtime_client.ts"
import type {
  AppView,
  BackendConnection,
  ChannelDirectory,
  ChannelDirectoryEntry,
  ChannelMembership,
  ServerConnection,
} from "../types.ts"

export interface ChannelDirectoryState {
  serverId: string | null
  channels: ChannelDirectoryEntry[]
  status: "idle" | "loading" | "ready" | "error"
  error: string | null
  joinError: string | null
  joiningChannel: string | null
  page: number
  pageSize: number
  query: string
  totalChannels: number
  totalPages: number
}

const emptyDirectory: ChannelDirectoryState = {
  serverId: null,
  channels: [],
  status: "idle",
  error: null,
  joinError: null,
  joiningChannel: null,
  page: 1,
  pageSize: 25,
  query: "",
  totalChannels: 0,
  totalPages: 1,
}

interface ChannelDirectoryOptions {
  activeServerIdRef: MutableRefObject<string | null>
  apiClient: ApiClient
  applyJoinedChannel: (
    connection: BackendConnection,
    membership: ChannelMembership,
    rejectionVersions?: Map<string, number>
  ) => boolean | undefined
  connectionsRef: MutableRefObject<ServerConnection[]>
  joinRejectionVersionsRef: MutableRefObject<Map<string, number>>
  realtimeClientRef: MutableRefObject<RealtimeClient | null>
  setActiveServerId: Dispatch<SetStateAction<string | null>>
  setView: Dispatch<SetStateAction<AppView>>
  viewRef: MutableRefObject<AppView>
}

export default function useChannelDirectory({
  activeServerIdRef,
  apiClient,
  applyJoinedChannel,
  connectionsRef,
  joinRejectionVersionsRef,
  realtimeClientRef,
  setActiveServerId,
  setView,
  viewRef,
}: ChannelDirectoryOptions) {
  const [channelDirectory, setChannelDirectory] = useState<ChannelDirectoryState>(emptyDirectory)
  const requestRef = useRef(0)

  function cancelChannelDirectory(): void {
    requestRef.current += 1
  }

  function beginChannelDirectoryRequest(): number {
    return ++requestRef.current
  }

  function applyChannelDirectory(directory?: ChannelDirectory, requestId = requestRef.current): boolean {
    if (!directory || requestId !== requestRef.current) return false

    const server = connectionsRef.current.find(
      (connection) => connection.server_connection_id === directory?.server_connection_id
    )
    if (!server) return false

    activeServerIdRef.current = server.id
    viewRef.current = "directory"
    setActiveServerId(server.id)
    setChannelDirectory({
      serverId: server.id,
      channels: directory.channels || [],
      status: "ready",
      error: null,
      joinError: null,
      joiningChannel: null,
      page: directory.page || 1,
      pageSize: directory.page_size || 25,
      query: directory.query || "",
      totalChannels: directory.total_channels || 0,
      totalPages: directory.total_pages || 1,
    })
    setView("directory")
    return true
  }

  async function requestChannelDirectory(server: ServerConnection, query: string, page: number): Promise<void> {
    if (!server) return
    const requestId = beginChannelDirectoryRequest()

    activeServerIdRef.current = server.id
    viewRef.current = "directory"
    setActiveServerId(server.id)
    setChannelDirectory({
      serverId: server.id,
      channels: [],
      status: "loading",
      error: null,
      joinError: null,
      joiningChannel: null,
      page,
      pageSize: 25,
      query,
      totalChannels: 0,
      totalPages: 1,
    })
    setView("directory")

    if (!server.server_connection_id || !realtimeClientRef.current) {
      setChannelDirectory((current) =>
        current.serverId === server.id
          ? {...current, status: "error", error: "Connect to this server before browsing its channels."}
          : current
      )
      return
    }

    try {
      const reply = await realtimeClientRef.current.push<{directory: ChannelDirectory}>("server:list", {
        page,
        query,
        server_connection_id: server.server_connection_id,
      })
      if (
        requestId !== requestRef.current ||
        viewRef.current !== "directory" ||
        activeServerIdRef.current !== server.id
      ) return
      applyChannelDirectory(reply.directory, requestId)
    } catch (error: unknown) {
      if (
        requestId !== requestRef.current ||
        viewRef.current !== "directory" ||
        activeServerIdRef.current !== server.id
      ) return

      setChannelDirectory((current) =>
        current.serverId === server.id
          ? {
              ...current,
              status: "error",
              error: channelDirectoryError((error as CommandError | null)?.reason),
              joiningChannel: null,
            }
          : current
      )
    }
  }

  function openChannelDirectory(
    server?: ServerConnection | null,
    options: {page?: number; query?: string} = {}
  ): Promise<void> {
    if (!server) return Promise.resolve()
    return requestChannelDirectory(server, options.query || "", options.page || 1)
  }

  function searchChannelDirectory(query: string): Promise<void> {
    const server = connectionsRef.current.find((connection) => connection.id === channelDirectory.serverId)
    if (!server) return Promise.resolve()
    return requestChannelDirectory(server, query, 1)
  }

  function changeChannelDirectoryPage(page: number): Promise<void> {
    const server = connectionsRef.current.find((connection) => connection.id === channelDirectory.serverId)
    if (!server) return Promise.resolve()
    return requestChannelDirectory(server, channelDirectory.query, page)
  }

  async function joinDirectoryChannel(channelName: string): Promise<void> {
    const server = connectionsRef.current.find((connection) => connection.id === channelDirectory.serverId)
    if (!server?.server_connection_id || !channelName) return

    const channel = channelName.trim()
    const rejectionVersions = new Map(joinRejectionVersionsRef.current)
    setChannelDirectory((current) => ({...current, joinError: null, joiningChannel: channel}))

    try {
      const joined = await apiClient.joinChannel(server.server_connection_id, channel)
      const applied = applyJoinedChannel(
        {...server, id: server.server_connection_id},
        joined.channel,
        rejectionVersions
      )

      if (!applied) {
        setChannelDirectory((current) => ({
          ...current,
          joinError: `Could not join ${channel}. Check the name and channel permissions, then try Join again.`,
          joiningChannel: null,
        }))
      }
    } catch (_error) {
      setChannelDirectory((current) => ({
        ...current,
        joinError: `Could not join ${channel}. Check the name and channel permissions, then try Join again.`,
        joiningChannel: null,
      }))
    }
  }

  return {
    applyChannelDirectory,
    beginChannelDirectoryRequest,
    cancelChannelDirectory,
    changeChannelDirectoryPage,
    channelDirectory,
    joinDirectoryChannel,
    openChannelDirectory,
    searchChannelDirectory,
  }
}
