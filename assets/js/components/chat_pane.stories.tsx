import {useState} from "react"
import ChatPane from "./chat_pane.tsx"
import type {ComponentProps} from "react"

const commandCatalog = [
  {name: "/join", usage: "/join #channel", description: "Join a channel", contexts: ["channel"], availability: "enabled"},
  {name: "/me", usage: "/me action", description: "Send an action", contexts: ["channel"], availability: "enabled"},
]

const activeChannel = {
  id: "channel:42",
  channel: "#elixir",
  connection: {host: "irc.example.net", status: "connected"},
}

const messages = [
  {id: "pane-1", nick: "mira", body: "The new chat pane is ready to preview.", kind: "message", occurredAt: "2026-08-25T15:00:00Z"},
  {id: "pane-2", nick: "akash", body: "Nice — the timeline and composer work together here.", kind: "message", occurredAt: "2026-08-25T15:02:00Z"},
  {id: "pane-3", body: "lena joined #elixir", kind: "system", occurredAt: "2026-08-25T15:03:00Z"},
]

type ChatPaneArgs = ComponentProps<typeof ChatPane>

function InteractiveChatPane(args: ChatPaneArgs) {
  const [draft, setDraft] = useState(args.draft)

  return (
    <ChatPane
      {...args}
      draft={draft}
      onLoadOlderMessages={() => {}}
      onReadingStateChange={() => {}}
      onRetryMessage={() => {}}
      onSendMessage={(event) => event.preventDefault()}
      onUpdateDraft={setDraft}
    />
  )
}

export default {
  title: "Chat/ChatPane",
  component: ChatPane,
  render: (args: ChatPaneArgs) => <InteractiveChatPane {...args} />,
  decorators: [
    (Story: React.ComponentType) => (
      <div className="flex h-[36rem] w-[52rem] max-w-[calc(100vw-2rem)] overflow-hidden border border-slate-800">
        <Story />
      </div>
    ),
  ],
  args: {
    activeChannel,
    commandCatalog,
    composerError: null,
    connectionHealth: "connected",
    draft: "",
    messages,
  },
}

export const Conversation = {}

export const EmptyChannel = {
  args: {messages: []},
}

export const WithDraft = {
  args: {draft: "A message composed inside the full chat pane"},
}

export const ComposerError = {
  args: {
    composerError: "Join exactly one valid channel. Usage: /join #channel",
    draft: "/join",
  },
}

export const Reconnecting = {
  args: {
    activeChannel: {...activeChannel, connection: {...activeChannel.connection, status: "reconnecting"}},
    connectionHealth: "reconnecting",
  },
}

export const FailedMessage = {
  args: {
    messages: [
      ...messages,
      {id: "pane-failed", nick: "mira", body: "This message could not be delivered.", kind: "message", occurredAt: "2026-08-25T15:04:00Z", failed: true},
    ],
  },
}

export const MobileWidth = {
  decorators: [
    (Story: React.ComponentType) => (
      <div className="flex h-[36rem] w-80 max-w-full overflow-hidden border border-slate-800">
        <Story />
      </div>
    ),
  ],
}
