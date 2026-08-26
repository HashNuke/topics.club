import {useState} from "react"
import ServerBufferPane from "./server_buffer_pane.tsx"
import type {ComponentProps} from "react"

const server = {
  id: "server:42",
  host: "irc.example.net",
  status: "connected",
}

const messages = [
  {id: "server-1", body: "Connected to irc.example.net.", kind: "system", occurredAt: "2026-08-25T14:58:00Z"},
  {id: "server-2", nick: "NickServ", body: "This nickname is registered.", kind: "notice", occurredAt: "2026-08-25T14:59:00Z"},
  {id: "server-3", body: "Joined #elixir.", kind: "system", occurredAt: "2026-08-25T15:00:00Z"},
]

const commandCatalog = [
  {name: "/join", usage: "/join #channel", description: "Join a channel", contexts: ["server"], availability: "enabled"},
  {name: "/list", usage: "/list", description: "Browse channels", contexts: ["server"], availability: "enabled"},
  {name: "/quote", usage: "/quote command", description: "Send a raw IRC command", contexts: ["server"], availability: "enabled"},
]

type ServerBufferArgs = ComponentProps<typeof ServerBufferPane>

function InteractiveServerBuffer(args: ServerBufferArgs) {
  const [draft, setDraft] = useState(args.draft)

  return (
    <ServerBufferPane
      {...args}
      draft={draft}
      onLoadOlderMessages={() => {}}
      onReadingStateChange={() => {}}
      onReconnectServer={() => {}}
      onSendMessage={(event) => event.preventDefault()}
      onUpdateDraft={setDraft}
    />
  )
}

export default {
  title: "Chat/ServerBufferPane",
  component: ServerBufferPane,
  render: (args: ServerBufferArgs) => <InteractiveServerBuffer {...args} />,
  decorators: [
    (Story: React.ComponentType) => (
      <div className="flex h-[36rem] w-[52rem] max-w-[calc(100vw-2rem)] overflow-hidden border border-slate-800">
        <Story />
      </div>
    ),
  ],
  args: {
    commandCatalog,
    composerError: null,
    connectionHealth: "connected",
    draft: "",
    messages,
    server,
  },
}

export const Connected = {}

export const Empty = {
  args: {messages: []},
}

export const Reconnecting = {
  args: {
    connectionHealth: "reconnecting",
    server: {...server, status: "reconnecting"},
  },
}

export const ConnectionError = {
  args: {
    server: {...server, status: "errored"},
  },
}

export const ComposerError = {
  args: {
    composerError: "That slash command is not supported.",
    draft: "/unknown",
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
