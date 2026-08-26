import {useEffect, useRef, useState, type MutableRefObject} from "react"
import type {
  RealtimeClient,
  RealtimeHandlers,
  RealtimePayload,
} from "../realtime_client.ts"
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

    const forward = (name: keyof RealtimeHandlers) => (payload: RealtimePayload) => {
      const handler = handlersRef.current[name] as ((value: RealtimePayload) => void) | undefined
      handler?.(payload)
    }
    const connected = () => {
      setConnectionHealth("connected")
      defer(() => onConnectedRef.current?.())
    }
    const realtimeClient = realtimeClientFactory({
      handlers: {
        onMessage: forward("onMessage"),
        onMention: forward("onMention"),
        onBufferMessage: forward("onBufferMessage"),
        onBufferJoined: forward("onBufferJoined"),
        onBufferLeft: forward("onBufferLeft"),
        onBufferRead: forward("onBufferRead"),
        onPresenceDiff: forward("onPresenceDiff"),
        onPresenceSync: forward("onPresenceSync"),
        onServerStatus: forward("onServerStatus"),
        onNotificationMention: forward("onNotificationMention"),
        onOpen: connected,
        onClose: () => setConnectionHealth("reconnecting"),
        onError: () => setConnectionHealth("degraded"),
        onJoinOk: connected,
        onJoinError: () => setConnectionHealth("degraded"),
        onJoinTimeout: () => setConnectionHealth("degraded"),
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

function defer(callback: () => void): void {
  if (typeof queueMicrotask === "function") {
    queueMicrotask(callback)
    return
  }

  Promise.resolve().then(callback)
}
