import React from "react"
import type {TimelineMessage} from "../types.ts"

const META_MESSAGE_KINDS = [
  "system",
  "command",
  "join",
  "part",
  "quit",
  "nick",
  "mode",
  "kick",
  "topic",
  "notice",
  "error",
]

export default function MessageRow({message, onMentionNick, onRetryMessage}: {message: TimelineMessage; onMentionNick?: (nick: string) => void; onRetryMessage?: (message: TimelineMessage) => void}) {
  if (META_MESSAGE_KINDS.includes(message.kind || "")) {
    return (
      <div
        className={[
          "px-2 py-1 text-xs italic",
          message.kind === "error" ? "text-rose-300" : "text-emerald-300",
        ].join(" ")}
        data-command-status={message.kind === "command" ? message.metadata?.command_status : undefined}
      >
        {message.body}
      </div>
    )
  }

  const nick = message.nick

  return (
    <div className="group relative rounded-md px-2 py-1.5 text-sm leading-6 hover:bg-slate-900/70">
      {nick && onMentionNick
        ? (
            <button
              aria-label={`Mention ${nick}`}
              className="rounded-sm font-semibold text-amber-200 transition hover:text-amber-100 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-cyan-300/70"
              onClick={() => onMentionNick(nick)}
              type="button"
            >
              {nick}
            </button>
          )
        : <span className="font-semibold text-amber-200">{nick}</span>}
      <span className="text-slate-500">: </span>
      <span className="break-words text-slate-200">{message.body}</span>
      {message.pending && <span className="ml-2 text-xs text-slate-500">sending</span>}
      {message.failed && (
        <button
          className="ml-2 rounded border border-rose-400/40 px-1.5 py-0.5 text-xs font-semibold text-rose-200 transition hover:border-rose-200 hover:text-white"
          onClick={() => onRetryMessage?.(message)}
          type="button"
        >
          Retry
        </button>
      )}
      <time
        className="pointer-events-none absolute right-2 top-1.5 rounded bg-slate-950/90 px-1.5 text-xs text-slate-500 opacity-0 transition-opacity group-hover:opacity-100 group-focus-within:opacity-100"
        dateTime={message.occurredAt}
      >
        {formatTime(message.occurredAt)}
      </time>
    </div>
  )
}

function formatTime(value?: string): string {
  return new Intl.DateTimeFormat([], {hour: "numeric", minute: "2-digit"}).format(new Date(value || 0))
}
