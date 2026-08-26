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
  const internalClientRef = useRef<RealtimeClient | null>(null)
  const realtimeClientRef = providedClientRef || internalClientRef
  const handlersRef = useRef(handlers)
  const onConnectedRef = useRef(onConnected)

  handlersRef.current = handlers
  onConnectedRef.current = onConnected

  useEffect(() => {
    if (!sessionKey || !realtimeClientFactory) return

    const joined = () => {
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
        onNotificationMention: (payload) => handlersRef.current.onNotificationMention?.(payload),
        onNotificationDirectMessage: (payload) => handlersRef.current.onNotificationDirectMessage?.(payload),
        onNotificationPreference: (payload) => handlersRef.current.onNotificationPreference?.(payload),
        onOpen: () => setConnectionHealth("reconnecting"),
        onClose: () => setConnectionHealth("reconnecting"),
        onError: () => setConnectionHealth("degraded"),
        onJoinOk: joined,
        onJoinError: () => setConnectionHealth("degraded"),
        onJoinTimeout: () => setConnectionHealth("degraded"),
        onChannelError: () => setConnectionHealth("reconnecting"),
        onChannelClose: () => setConnectionHealth("degraded"),
      },
    })

    realtimeClientRef.current = realtimeClient.connect()

    return () => {
      realtimeClient.disconnect()
      realtimeClientRef.current = null
      setConnectionHealth("disconnected")
    }
  }, [realtimeClientFactory, sessionKey])

  function retryRealtimeConnection() {
    if (!realtimeClientRef.current?.reconnect) return

    setConnectionHealth("reconnecting")
    realtimeClientRef.current.reconnect()
  }

  return {connectionHealth, realtimeClientRef, retryRealtimeConnection}
}
