import {useRef, useState} from "react"
import {channelDirectoryError} from "../app_feedback.ts"

const emptyDirectory = {
  serverId: null,
  channels: [],
  status: "idle",
  error: null,
  joinError: null,
  joiningChannel: null,
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
}) {
  const [channelDirectory, setChannelDirectory] = useState(emptyDirectory)
  const requestRef = useRef(0)

  function cancelChannelDirectory() {
    requestRef.current += 1
  }

  function beginChannelDirectoryRequest() {
    return ++requestRef.current
  }

  function applyChannelDirectory(directory, requestId = requestRef.current) {
    if (requestId !== requestRef.current) return false

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
    })
    setView("directory")
    return true
  }

  async function openChannelDirectory(server) {
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
      const reply = await realtimeClientRef.current.push("server:list", {
        server_connection_id: server.server_connection_id,
      })
      if (
        requestId !== requestRef.current ||
        viewRef.current !== "directory" ||
        activeServerIdRef.current !== server.id
      ) return
      applyChannelDirectory(reply.directory, requestId)
    } catch (error) {
      setChannelDirectory((current) =>
        current.serverId === server.id
          ? {
              ...current,
              status: "error",
              error: channelDirectoryError(error?.reason),
              joiningChannel: null,
            }
          : current
      )
    }
  }

  async function joinDirectoryChannel(channelName) {
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
    channelDirectory,
    joinDirectoryChannel,
    openChannelDirectory,
  }
}
