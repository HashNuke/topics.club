import React, {Fragment} from "react"
import MessageRow from "./message_row.jsx"

export default function MessageTimeline({messages, onRetryMessage}) {
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

function TimeSeparator({value}) {
  return (
    <div className="my-4 flex items-center justify-center gap-3 text-xs text-slate-600">
      <span className="h-px flex-1 bg-slate-800/80" />
      <time dateTime={value}>{formatTimestamp(value)}</time>
      <span className="h-px flex-1 bg-slate-800/80" />
    </div>
  )
}

function minutesBetween(previous, current) {
  return Math.abs(new Date(current).getTime() - new Date(previous).getTime()) / 60_000
}

function formatTimestamp(value) {
  return new Intl.DateTimeFormat([], {
    month: "short",
    day: "numeric",
    hour: "numeric",
    minute: "2-digit",
  }).format(new Date(value))
}
