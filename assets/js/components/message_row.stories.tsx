import MessageRow from "./message_row.tsx"

const occurredAt = "2026-08-25T16:00:00Z"

export default {
  title: "Chat/MessageRow",
  component: MessageRow,
  decorators: [
    (Story: React.ComponentType) => (
      <div className="w-[42rem] max-w-[calc(100vw-2rem)]">
        <Story />
      </div>
    ),
  ],
  args: {
    message: {
      id: "message-default",
      nick: "mira",
      body: "The IRC session is connected and ready.",
      kind: "message",
      occurredAt,
    },
    onRetryMessage: () => {},
  },
}

export const Default = {}

export const Pending = {
  args: {
    message: {
      id: "message-pending",
      nick: "mira",
      body: "Sending this message now.",
      kind: "message",
      occurredAt,
      pending: true,
    },
  },
}

export const Failed = {
  args: {
    message: {
      id: "message-failed",
      nick: "mira",
      body: "This message could not be delivered.",
      kind: "message",
      occurredAt,
      failed: true,
    },
  },
}

export const System = {
  args: {
    message: {
      id: "message-system",
      body: "Connected to irc.example.net.",
      kind: "system",
      occurredAt,
    },
  },
}

export const Error = {
  args: {
    message: {
      id: "message-error",
      body: "Cannot send to channel: you are not joined.",
      kind: "error",
      occurredAt,
    },
  },
}

export const CommandSent = {
  args: {
    message: {
      id: "message-command-sent",
      body: "WHOIS mira",
      kind: "command",
      occurredAt,
      metadata: {command_status: "sent"},
    },
  },
}

export const CommandCompleted = {
  args: {
    message: {
      id: "message-command-completed",
      body: "WHOIS mira",
      kind: "command",
      occurredAt,
      metadata: {command_status: "completed"},
    },
  },
}

export const CommandFailed = {
  args: {
    message: {
      id: "message-command-failed",
      body: "WHOIS mira",
      kind: "command",
      occurredAt,
      metadata: {command_status: "failed"},
    },
  },
}

export const LongContent = {
  args: {
    message: {
      id: "message-long",
      nick: "akash",
      body:
        "A long IRC message should wrap naturally inside the available timeline width without pushing the timestamp or controls outside the conversation pane.",
      kind: "message",
      occurredAt,
    },
  },
}
