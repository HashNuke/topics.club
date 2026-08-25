import MessageTimeline from "./message_timeline.jsx"

const baseMessages = [
  {
    id: "timeline-1",
    nick: "mira",
    body: "The reconnect completed cleanly.",
    kind: "message",
    occurredAt: "2026-08-25T15:00:00Z",
  },
  {
    id: "timeline-2",
    nick: "akash",
    body: "Great, I can see the channel again.",
    kind: "message",
    occurredAt: "2026-08-25T15:04:00Z",
  },
]

export default {
  title: "Chat/MessageTimeline",
  component: MessageTimeline,
  decorators: [
    (Story) => (
      <div className="w-[42rem] max-w-[calc(100vw-2rem)] space-y-1">
        <Story />
      </div>
    ),
  ],
  args: {
    messages: baseMessages,
    onRetryMessage: () => {},
  },
}

export const Conversation = {}

export const Empty = {
  args: {
    messages: [],
  },
}

export const WithTimeGap = {
  args: {
    messages: [
      ...baseMessages,
      {
        id: "timeline-3",
        nick: "lena",
        body: "Catching up after lunch.",
        kind: "message",
        occurredAt: "2026-08-25T16:10:00Z",
      },
    ],
  },
}

export const MixedEvents = {
  args: {
    messages: [
      {
        id: "timeline-system",
        body: "Connected to irc.example.net.",
        kind: "system",
        occurredAt: "2026-08-25T15:00:00Z",
      },
      {
        id: "timeline-chat",
        nick: "mira",
        body: "Hello everyone.",
        kind: "message",
        occurredAt: "2026-08-25T15:01:00Z",
      },
      {
        id: "timeline-notice",
        body: "Channel mode is +nt.",
        kind: "notice",
        occurredAt: "2026-08-25T15:02:00Z",
      },
      {
        id: "timeline-error",
        body: "Cannot send to channel: you are not joined.",
        kind: "error",
        occurredAt: "2026-08-25T15:03:00Z",
      },
    ],
  },
}

export const RetryableMessage = {
  args: {
    messages: [
      {
        id: "timeline-failed",
        nick: "mira",
        body: "This message could not be delivered.",
        kind: "message",
        occurredAt: "2026-08-25T15:00:00Z",
        failed: true,
      },
    ],
  },
}

export const MobileWidth = {
  decorators: [
    (Story) => (
      <div className="w-80 max-w-full">
        <Story />
      </div>
    ),
  ],
}
