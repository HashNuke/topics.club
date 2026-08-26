import {useEffect, useRef, useState, type MutableRefObject} from "react"
import type {RealtimeClient, RealtimeHandlers} from "../realtime_client.ts"
import type {ConnectionHealth, EntityId} from "../types.ts"

interface RealtimeConnectionOptions {
  handlers: RealtimeHandlers
  onConnected?: () => void
  realtimeClientFactory?: ((options: {handlers: RealtimeHandlers}) => RealtimeClient) | null
  realtimeClientRef?: MutableRefObject<RealtimeClient | null>
  sessionKey?: EntityId | null
}

export default function useRealtimeConnection({handlers, onConnected, realtimeClientFactory, realtimeClientRef: providedClientRef, sessionKey}: RealtimeConnectionOptions) {
  const [connectionHealth, setConnectionHealth] = useState<ConnectionHealth>("disconnected")
  const [clientGeneration, setClientGeneration] = useState(0)
  const channelClosedRef = useRef(false)
  const internalClientRef = useRef<RealtimeClient | null>(null)
  const realtimeClientRef = providedClientRef || internalClientRef
  const handlersRef = useRef(handlers)
  const onConnectedRef = useRef(onConnected)

  handlersRef.current = handlers
  onConnectedRef.current = onConnected

  useEffect(() => {
    if (!sessionKey || !realtimeClientFactory) return

    let active = true
    channelClosedRef.current = false

    const joined = () => {
      if (!active) return
      channelClosedRef.current = false
      setConnectionHealth("connected")
      onConnectedRef.current?.()
    }
    const realtimeClient = realtimeClientFactory({
      handlers: {
        onMessage: (payload) => handlersRef.current.onMessage?.(payload),
        onBufferMessage: (payload) => handlersRef.current.onBufferMessage?.(payload),
        onBufferJoined: (payload) => handlersRef.current.onBufferJoined?.(payload),
        onDirectMessageThread: (payload) => handlersRef.current.onDirectMessageThread?.(payload),
        onDirectMessageClosed: (payload) => handlersRef.current.onDirectMessageClosed?.(payload),
        onBufferLeft: (payload) => handlersRef.current.onBufferLeft?.(payload),
        onBufferRead: (payload) => handlersRef.current.onBufferRead?.(payload),
        onPresenceDiff: (payload) => handlersRef.current.onPresenceDiff?.(payload),
        onPresenceSync: (payload) => handlersRef.current.onPresenceSync?.(payload),
        onServerStatus: (payload) => handlersRef.current.onServerStatus?.(payload),
        onNotificationPreference: (payload) => handlersRef.current.onNotificationPreference?.(payload),
        onOpen: () => active && setConnectionHealth("reconnecting"),
        onClose: () => active && setConnectionHealth("reconnecting"),
        onError: () => active && setConnectionHealth("degraded"),
        onJoinOk: joined,
        onJoinError: () => active && setConnectionHealth("degraded"),
        onJoinTimeout: () => active && setConnectionHealth("degraded"),
        onChannelError: () => active && setConnectionHealth("reconnecting"),
        onChannelClose: () => {
          if (!active) return
          channelClosedRef.current = true
          setConnectionHealth("degraded")
        },
      },
    })

    realtimeClientRef.current = realtimeClient.connect()

    return () => {
      active = false
      realtimeClient.disconnect()
      realtimeClientRef.current = null
    }
  }, [clientGeneration, realtimeClientFactory, sessionKey])

  function retryRealtimeConnection() {
    if (channelClosedRef.current) {
      setConnectionHealth("reconnecting")
      setClientGeneration((generation) => generation + 1)
      return
    }

    if (!realtimeClientRef.current?.reconnect) return

    setConnectionHealth("reconnecting")
    realtimeClientRef.current.reconnect()
  }

  return {connectionHealth, realtimeClientRef, retryRealtimeConnection}
}
