import React from "react"
import {
  NewMessagesButton,
  composerStatusLabel,
  useChatScroll,
  visibleTimelineMessages,
} from "./chat_pane.tsx"
import ChatComposer from "./chat_composer.tsx"
import ConnectionIssueCard from "./connection_issue_card.tsx"
import MessageTimeline from "./message_timeline.tsx"
import {fallbackConnectionIssue, latestConnectionIssue, type ConnectionEditFocus} from "../connection_issue.ts"
import type {CommandCatalogEntry, ConnectionHealth, ServerConnection, TimelineMessage} from "../types.ts"

export interface ServerBufferPaneProps {
  commandCatalog: CommandCatalogEntry[]
  composerError?: string | null
  connectionHealth: ConnectionHealth
  draft: string
  messages: TimelineMessage[]
  onEditServer?: (server: ServerConnection, focus: ConnectionEditFocus) => void
  onLoadOlderMessages?: (bufferId?: string) => void
  onReadingStateChange?: (bufferId: string | undefined, readingOlder: boolean) => void
  onReconnectServer?: (server: ServerConnection) => void
  onUseRandomNickname?: (server: ServerConnection) => boolean | Promise<boolean>
  server?: ServerConnection
  onSendMessage: React.FormEventHandler<HTMLFormElement>
  onUpdateDraft: (value: string) => void
}

export function ServerBufferPane({commandCatalog, composerError, connectionHealth, draft, messages, onEditServer, onLoadOlderMessages, onReadingStateChange, onReconnectServer, onUseRandomNickname, server, onSendMessage, onUpdateDraft}: ServerBufferPaneProps) {
  const issue = server?.status === "errored" ? latestConnectionIssue(messages) || fallbackConnectionIssue() : null
  const {newMessageCount, readingOlder, scrollRef, scrollToBottom} = useChatScroll(messages, {
    contentRevision: issue ? `${issue.code}:${issue.title}` : server?.status,
    onNearTop: () => onLoadOlderMessages?.(server?.id),
    onReadingStateChange: (nextReadingOlder) => onReadingStateChange?.(server?.id, nextReadingOlder),
  })
  const visibleMessages = visibleTimelineMessages(messages, readingOlder)

  if (!server) return null
  const showsIssueCard = Boolean(issue && onEditServer && onReconnectServer && onUseRandomNickname)
  const timelineMessages = issue
    ? visibleMessages.filter((message) => message.metadata?.connection_issue !== issue)
    : visibleMessages

  return (
    <section className="flex min-h-0 flex-1 flex-col bg-[var(--app-canvas)]">
      <div id="server-scrollback" ref={scrollRef} className="min-h-0 flex-1 overflow-y-auto px-3 py-4 sm:px-6">
        <div className="mx-auto max-w-4xl">
          <div className="mb-4 rounded-lg border border-slate-800 bg-[var(--app-panel)] p-4">
            <div className="text-xs font-semibold uppercase tracking-[0.18em] text-slate-500">Server buffer</div>
            <h2 className="mt-2 text-xl font-semibold tracking-tight">{server.host}</h2>
            <p className="mt-2 text-sm leading-6 text-slate-500">
              Notices, connection logs, service replies, and server-level commands live here.
            </p>
          </div>
          {!issue && <ServerStatusBanner server={server} onReconnectServer={onReconnectServer} />}
          {timelineMessages.length > 0
            ? <MessageTimeline messages={timelineMessages} />
            : !showsIssueCard && <MessageTimeline messages={[]} />}
          {issue && onEditServer && onReconnectServer && onUseRandomNickname && (
            <ConnectionIssueCard issue={issue} onEditServer={onEditServer} onReconnectServer={onReconnectServer} onUseRandomNickname={onUseRandomNickname} server={server} />
          )}
        </div>
      </div>
      {newMessageCount > 0 && <NewMessagesButton count={newMessageCount} onClick={scrollToBottom} />}
      <ChatComposer
        commandCatalog={commandCatalog}
        context="server"
        error={composerError}
        inputId="server-command-input"
        draft={draft}
        disabled={server.status !== "connected" || connectionHealth !== "connected"}
        readOnly={server.status !== "connected"}
        statusLabel={showsIssueCard ? null : composerStatusLabel(server.status, connectionHealth)}
        onSendMessage={onSendMessage}
        onUpdateDraft={onUpdateDraft}
        placeholder="Try /msg NickServ help or /quote WHOIS nick"
      />
    </section>
  )
}

export function ServerStatusBanner({onReconnectServer, server}: {onReconnectServer?: (server: ServerConnection) => void; server?: ServerConnection}) {
  if (!server || server.status === "connected" || server.status === "errored") return null

  const label = `Server ${server.status || "offline"}`
  const canReconnect = server.status !== "connecting"

  return (
    <div
      className="mb-4 flex flex-wrap items-center justify-between gap-3 rounded-md border border-amber-300/25 bg-amber-300/10 px-3 py-2 text-sm text-amber-100"
      role="status"
    >
      <div>
        <div className="font-semibold">{label}</div>
        <div className="text-xs text-amber-100/70">IRC messages for this server may be delayed until it reconnects.</div>
      </div>
      {canReconnect && (
        <button
          className="rounded-md border border-amber-200/40 px-3 py-1.5 text-xs font-semibold text-amber-50 transition hover:border-amber-100 hover:bg-amber-100 hover:text-amber-950"
          onClick={() => onReconnectServer?.(server)}
          type="button"
        >
          Reconnect
        </button>
      )}
    </div>
  )
}

export default ServerBufferPane
