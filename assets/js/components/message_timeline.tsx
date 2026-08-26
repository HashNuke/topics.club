import React, {Fragment} from "react"
import MessageRow from "./message_row.tsx"
import type {ChatMessage} from "../types.ts"

export default function MessageTimeline({messages, onRetryMessage}: {messages: ChatMessage[]; onRetryMessage?: (message: ChatMessage) => void}) {
  return (
    <>
      {messages.map((message, index) => {
        const previous = messages[index - 1]
        const showSeparator = !previous || minutesBetween(previous.occurredAt, message.occurredAt) >= 30

        return (
          <Fragment key={message.id}>
            {showSeparator && <TimeSeparator value={message.occurredAt} />}
            <MessageRow message={message} onRetryMessage={onRetryMessage} />
          </Fragment>
        )
      })}
    </>
  )
}

function TimeSeparator({value}: {value?: string}) {
  return (
    <div className="my-4 flex items-center justify-center gap-3 text-xs text-slate-600">
      <span className="h-px flex-1 bg-slate-800/80" />
      <time dateTime={value}>{formatTimestamp(value)}</time>
      <span className="h-px flex-1 bg-slate-800/80" />
    </div>
  )
}

function minutesBetween(previous?: string, current?: string): number {
  return Math.abs(new Date(current || 0).getTime() - new Date(previous || 0).getTime()) / 60_000
}

function formatTimestamp(value?: string): string {
  return new Intl.DateTimeFormat([], {
    month: "short",
    day: "numeric",
    hour: "numeric",
    minute: "2-digit",
  }).format(new Date(value || 0))
}
