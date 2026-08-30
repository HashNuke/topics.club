import React, {useEffect, useRef, useState} from "react"
import ChatComposer from "./chat_composer.tsx"
import MessageTimeline from "./message_timeline.tsx"
import type {Channel, CommandCatalogEntry, ConnectionHealth, EntityId, ServerConnection, TimelineMessage} from "../types.ts"

export const MESSAGE_RENDER_LIMIT = 400

export interface ChatPaneProps {
  activeChannel?: Channel
  commandCatalog: CommandCatalogEntry[]
  composerError?: string | null
  connectionHealth: ConnectionHealth
  draft: string
  messages: TimelineMessage[]
  messagesLoading?: boolean
  onLoadOlderMessages?: (bufferId?: string) => void
  onMentionNick?: (nick: string) => void
  onReadingStateChange?: (bufferId: string | undefined, readingOlder: boolean) => void
  onRetryMessage?: (message: TimelineMessage) => void
  onSendMessage: React.FormEventHandler<HTMLFormElement>
  onSelectServer?: (server: ServerConnection) => void
  onUpdateDraft: (value: string) => void
}

export function ChatPane({activeChannel, commandCatalog, composerError, connectionHealth, draft, messages, messagesLoading = false, onLoadOlderMessages, onMentionNick, onReadingStateChange, onRetryMessage, onSelectServer, onSendMessage, onUpdateDraft}: ChatPaneProps) {
  const {newMessageCount, readingOlder, scrollRef, scrollToBottom} = useChatScroll(messages, {
    onNearTop: () => onLoadOlderMessages?.(activeChannel?.id),
    onReadingStateChange: (nextReadingOlder) => onReadingStateChange?.(activeChannel?.id, nextReadingOlder),
  })
  const visibleMessages = visibleTimelineMessages(
    messages,
    readingOlder,
    activeChannel?.buffer_type === "direct_message" ? Number.POSITIVE_INFINITY : undefined
  )
  const sendDisabled = isRealtimeChannel(activeChannel) && !realtimeReadyFor(activeChannel, connectionHealth)
  const ircUnavailable = Boolean(isRealtimeChannel(activeChannel) && activeChannel?.connection?.status !== "connected")

  return (
    <section className="flex min-h-0 flex-1 flex-col bg-[var(--app-canvas)]">
      <div id="chat-scrollback" ref={scrollRef} className="min-h-0 flex-1 overflow-y-auto px-3 py-4 sm:px-6">
        <div className="mx-auto max-w-4xl space-y-1">
          <MessageTimeline loading={messagesLoading} messages={visibleMessages} onMentionNick={onMentionNick} onRetryMessage={onRetryMessage} />
        </div>
      </div>
      {newMessageCount > 0 && <NewMessagesButton count={newMessageCount} onClick={scrollToBottom} />}
      <ChatComposer
        commandCatalog={commandCatalog}
        context="channel"
        error={composerError}
        inputId="chat-message-input"
        draft={draft}
        disabled={sendDisabled}
        onStatusAction={activeChannel?.connection && activeChannel.connection.status !== "connected" ? () => onSelectServer?.(activeChannel.connection!) : undefined}
        readOnly={ircUnavailable}
        statusLabel={composerStatusLabel(activeChannel?.connection?.status, connectionHealth)}
        statusActionLabel={activeChannel?.connection && activeChannel.connection.status !== "connected" ? "View issue" : undefined}
        onSendMessage={onSendMessage}
        onUpdateDraft={onUpdateDraft}
        placeholder={activeChannel ? "Write a message" : "Choose a topic first"}
      />
    </section>
  )
}

export function NewMessagesButton({count, onClick}: {count: number; onClick: () => void}) {
  return (
    <div className="pointer-events-none -mt-12 flex justify-center">
      <button
        className="pointer-events-auto rounded-full border border-cyan-300/40 bg-cyan-300 px-3 py-1.5 text-xs font-semibold text-cyan-950 shadow-lg shadow-black/30 transition hover:bg-white"
        onClick={onClick}
        type="button"
      >
        {count} new {count === 1 ? "message" : "messages"}
      </button>
    </div>
  )
}

export function isRealtimeChannel(channel?: Channel | null): boolean {
  return Boolean(channel?.id?.startsWith("channel:") || channel?.id?.startsWith("direct:"))
}

export function realtimeReadyFor(channel: Channel | null | undefined, connectionHealth: ConnectionHealth): boolean {
  return Boolean(isRealtimeChannel(channel) && connectionHealth === "connected" && channel?.connection?.status === "connected")
}

export function composerStatusLabel(serverStatus: string | undefined, connectionHealth: ConnectionHealth): string | null {
  if (serverStatus === "connecting" || serverStatus === "reconnecting") return "Reconnecting..."
  if (serverStatus === "disconnected") return "Disconnected. Messages will resume after reconnect."
  if (serverStatus === "errored") return "Connection error. Reconnect to resume messages."
  if (connectionHealth === "reconnecting") return "Reconnecting..."
  if (connectionHealth === "degraded") return "Realtime connection degraded."
  return null
}

export function visibleTimelineMessages(messages: TimelineMessage[], readingOlder: boolean, limit = MESSAGE_RENDER_LIMIT): TimelineMessage[] {
  if (readingOlder || messages.length <= limit) return messages
  return messages.slice(-limit)
}

interface ChatScrollOptions {
  onNearTop?: () => void
  onReadingStateChange?: (readingOlder: boolean) => void
}

export function useChatScroll(messages: TimelineMessage[], {onNearTop, onReadingStateChange}: ChatScrollOptions = {}) {
  const scrollRef = useRef<HTMLDivElement | null>(null)
  const previousScrollHeightRef = useRef(0)
  const previousLastMessageIdRef = useRef<EntityId | null>(null)
  const previousMessageLengthRef = useRef(0)
  const readingOlderRef = useRef(false)
  const [readingOlder, setReadingOlder] = useState(false)
  const [newMessageCount, setNewMessageCount] = useState(0)
  const [viewportRevision, setViewportRevision] = useState(0)

  useEffect(() => {
    const node = scrollRef.current
    if (!node) return
    const updateReadingState = ({loadOlder = false}: {loadOlder?: boolean} = {}) => {
      const distanceFromBottom = node.scrollHeight - node.scrollTop - node.clientHeight
      const nextReadingOlder = distanceFromBottom > 96
      if (readingOlderRef.current !== nextReadingOlder) {
        readingOlderRef.current = nextReadingOlder
        setReadingOlder(nextReadingOlder)
        onReadingStateChange?.(nextReadingOlder)
      }
      if (!nextReadingOlder) setNewMessageCount(0)
      if (loadOlder && node.scrollTop <= 80 && node.scrollHeight > node.clientHeight) onNearTop?.()
    }

    updateReadingState()
    const handleScroll = () => updateReadingState({loadOlder: true})
    node.addEventListener("scroll", handleScroll)

    return () => node.removeEventListener("scroll", handleScroll)
  }, [onNearTop, onReadingStateChange])

  useEffect(() => {
    const node = scrollRef.current
    if (!node || readingOlder) return
    node.scrollTop = node.scrollHeight
  }, [messages.length, readingOlder, viewportRevision])

  useEffect(() => {
    const viewport = window.visualViewport
    let frame: number | null = null

    const handleViewportChange = () => {
      if (frame) cancelAnimationFrame(frame)
      frame = requestAnimationFrame(() => setViewportRevision((current) => current + 1))
    }

    viewport?.addEventListener("resize", handleViewportChange)
    viewport?.addEventListener("scroll", handleViewportChange)
    window.addEventListener("resize", handleViewportChange)

    return () => {
      if (frame) cancelAnimationFrame(frame)
      viewport?.removeEventListener("resize", handleViewportChange)
      viewport?.removeEventListener("scroll", handleViewportChange)
      window.removeEventListener("resize", handleViewportChange)
    }
  }, [])

  useEffect(() => {
    const node = scrollRef.current
    if (!node || !readingOlder) return

    const previousScrollHeight = previousScrollHeightRef.current
    if (previousScrollHeight > 0 && node.scrollHeight > previousScrollHeight) {
      node.scrollTop += node.scrollHeight - previousScrollHeight
    }

    previousScrollHeightRef.current = node.scrollHeight
  }, [messages.length, readingOlder])

  useEffect(() => {
    const lastMessage = messages[messages.length - 1]
    const previousLastMessageId = previousLastMessageIdRef.current
    const previousLength = previousMessageLengthRef.current

    if (
      readingOlderRef.current &&
      previousLastMessageId != null &&
      lastMessage?.id !== previousLastMessageId &&
      messages.length > previousLength
    ) {
      setNewMessageCount((current) => current + messages.length - previousLength)
    }

    previousLastMessageIdRef.current = lastMessage?.id ?? null
    previousMessageLengthRef.current = messages.length
  }, [messages])

  function scrollToBottom(): void {
    const node = scrollRef.current
    if (node) node.scrollTop = node.scrollHeight
    readingOlderRef.current = false
    setReadingOlder(false)
    onReadingStateChange?.(false)
    setNewMessageCount(0)
  }

  return {newMessageCount, readingOlder, scrollRef, scrollToBottom}
}

export default ChatPane
