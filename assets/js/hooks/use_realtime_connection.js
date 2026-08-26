import {useEffect, useRef, useState} from "react"

export default function useRealtimeConnection({handlers, onConnected, realtimeClientFactory, sessionKey}) {
  const [connectionHealth, setConnectionHealth] = useState("disconnected")
  const realtimeClientRef = useRef(null)
  const handlersRef = useRef(handlers)
  const onConnectedRef = useRef(onConnected)

  handlersRef.current = handlers
  onConnectedRef.current = onConnected

  useEffect(() => {
    if (!sessionKey || !realtimeClientFactory) return

    const forward = (name) => (...args) => handlersRef.current[name]?.(...args)
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

function defer(callback) {
  if (typeof queueMicrotask === "function") {
    queueMicrotask(callback)
    return
  }

  Promise.resolve().then(callback)
}
