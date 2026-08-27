import React, {Fragment} from "react"
import MessageRow from "./message_row.tsx"
import type {TimelineMessage} from "../types.ts"

export interface MessageTimelineProps {
  loading?: boolean
  messages: TimelineMessage[]
  onRetryMessage?: (message: TimelineMessage) => void
}

interface TimelineEntry {
  kind: "message" | "membership-events"
  messages: TimelineMessage[]
}

export default function MessageTimeline({loading = false, messages, onRetryMessage}: MessageTimelineProps) {
  if (loading) return <MessageTimelineSkeleton />
  if (messages.length === 0) return <EmptyMessageTimeline />

  const entries = groupContiguousMembershipEvents(messages)

  return (
    <>
      {entries.map((entry, index) => {
        const message = entry.messages[0]
        const previous = entries[index - 1]?.messages.at(-1)
        const showSeparator = !previous || minutesBetween(previous.occurredAt, message.occurredAt) >= 30

        return (
          <Fragment key={message.id ?? `timeline-${index}`}>
            {showSeparator && <TimeSeparator value={message.occurredAt} />}
            {entry.kind === "membership-events" && entry.messages.length > 1
              ? <MembershipEventSummary messages={entry.messages} />
              : <MessageRow message={message} onRetryMessage={onRetryMessage} />}
          </Fragment>
        )
      })}
    </>
  )
}

export function groupContiguousMembershipEvents(messages: TimelineMessage[]): TimelineEntry[] {
  return messages.reduce<TimelineEntry[]>((entries, message) => {
    const membershipEvent = message.kind === "join" || message.kind === "quit"
    const previous = entries.at(-1)

    if (membershipEvent && previous?.kind === "membership-events") {
      previous.messages.push(message)
    } else {
      entries.push({kind: membershipEvent ? "membership-events" : "message", messages: [message]})
    }

    return entries
  }, [])
}

export function MembershipEventSummary({messages}: {messages: TimelineMessage[]}) {
  const joined = messages.filter((message) => message.kind === "join").length
  const quit = messages.filter((message) => message.kind === "quit").length
  const summary = [joined > 0 && `${joined} joined`, quit > 0 && `${quit} quit`].filter(Boolean).join(" · ")

  return (
    <div className="px-2 py-1 text-xs italic text-slate-500" data-membership-event-count={messages.length}>
      {summary}
    </div>
  )
}

export function MessageTimelineSkeleton() {
  return (
    <div aria-label="Loading messages" className="space-y-5 py-4" role="status">
      <span className="sr-only">Loading messages</span>
      {["w-2/3", "w-5/6", "w-1/2", "w-3/4"].map((width, index) => (
        <div aria-hidden="true" className="animate-pulse space-y-2 px-2" key={width}>
          <div className="h-3 w-20 rounded-full bg-slate-800" />
          <div className={["h-3 rounded-full bg-slate-800/70", width].join(" ")} />
          {index === 1 && <div className="h-3 w-1/3 rounded-full bg-slate-800/50" />}
        </div>
      ))}
    </div>
  )
}

export function EmptyMessageTimeline() {
  return (
    <div className="flex min-h-48 items-center justify-center px-6 py-12 text-center" role="status">
      <div>
        <div className="mx-auto grid size-10 place-items-center rounded-full border border-slate-800 bg-slate-900/70 text-slate-500">
          <span aria-hidden="true" className="text-lg font-semibold">#</span>
        </div>
        <p className="mt-4 text-sm font-semibold text-slate-300">No messages yet</p>
        <p className="mt-1 text-xs text-slate-500">New activity will appear here.</p>
      </div>
    </div>
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
