import {useState} from "react"
import ChatComposer from "./chat_composer.tsx"

const commandCatalog = [
  {
    name: "/join",
    usage: "/join #channel",
    description: "Join a channel",
    contexts: ["server", "channel"],
    availability: "enabled",
  },
  {
    name: "/list",
    usage: "/list",
    description: "Browse channels",
    contexts: ["server", "channel"],
    availability: "enabled",
  },
  {
    name: "/me",
    usage: "/me action",
    description: "Send an action",
    contexts: ["channel"],
    availability: "enabled",
  },
]

function InteractiveComposer(args) {
  const [draft, setDraft] = useState(args.draft)

  return (
    <ChatComposer
      {...args}
      draft={draft}
      onSendMessage={(event) => event.preventDefault()}
      onUpdateDraft={setDraft}
    />
  )
}

export default {
  title: "Chat/ChatComposer",
  component: ChatComposer,
  render: (args) => <InteractiveComposer {...args} />,
  parameters: {
    layout: "fullscreen",
  },
  args: {
    commandCatalog,
    context: "channel",
    disabled: false,
    draft: "",
    error: null,
    inputId: "storybook-chat-composer",
    placeholder: "Write a message",
    statusLabel: null,
  },
}

export const Empty = {}

export const WithDraft = {
  args: {
    draft: "A message ready to send",
  },
}

export const CommandSuggestions = {
  args: {
    draft: "/",
  },
}

export const ServerCommand = {
  args: {
    context: "server",
    draft: "/j",
    inputId: "storybook-server-composer",
    placeholder: "/msg NickServ help or /quote WHOIS nick",
  },
}

export const Error = {
  args: {
    draft: "/join",
    error: "Join exactly one valid channel. Usage: /join #channel",
  },
}

export const Disconnected = {
  args: {
    disabled: true,
    statusLabel: "Disconnected. Messages will resume after reconnect.",
  },
}

export const Reconnecting = {
  args: {
    disabled: true,
    statusLabel: "Reconnecting...",
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
  args: {
    draft: "A compact composer",
    statusLabel: "Reconnecting...",
  },
}
