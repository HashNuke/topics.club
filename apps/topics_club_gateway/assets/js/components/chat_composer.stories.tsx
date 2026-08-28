import {useState} from "react"
import ChatComposer from "./chat_composer.tsx"
import type {ComponentProps} from "react"
import type {CommandCatalogEntry} from "../types.ts"

const commandCatalog: CommandCatalogEntry[] = [
  {
    name: "/join",
    usage: "/join #channel",
    description: "Join a channel",
    required_permission: "user",
    contexts: ["server", "channel"],
    availability: "enabled",
    examples: ["/join #elixir"],
  },
  {
    name: "/list",
    usage: "/list",
    description: "Browse channels",
    required_permission: "user",
    contexts: ["server", "channel"],
    availability: "enabled",
    examples: ["/list"],
  },
  {
    name: "/me",
    usage: "/me action",
    description: "Send an action",
    required_permission: "user",
    contexts: ["channel"],
    availability: "enabled",
    examples: ["/me waves"],
  },
]

type ComposerArgs = ComponentProps<typeof ChatComposer>

function InteractiveComposer(args: ComposerArgs) {
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
  render: (args: ComposerArgs) => <InteractiveComposer {...args} />,
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

export const FiveLineDraft = {
  args: {
    draft: "First line\nSecond line\nThird line\nFourth line\nFifth line",
  },
}

export const CommandSuggestions = {
  args: {
    draft: "/",
  },
}

export const SmallViewportCommandSuggestions = {
  decorators: [
    (Story: React.ComponentType) => (
      <div className="flex h-dvh w-full items-end overflow-hidden">
        <Story />
      </div>
    ),
  ],
  parameters: {viewport: {defaultViewport: "mobile1"}},
  args: {
    commandCatalog: [
      ...commandCatalog,
      ...Array.from({length: 18}, (_, index) => ({
        name: `/command${index + 1}`,
        usage: `/command${index + 1} value`,
        description: `Example command ${index + 1}`,
        required_permission: "user",
        contexts: ["channel"],
        availability: "enabled",
        examples: [],
      } satisfies CommandCatalogEntry)),
    ],
    draft: "/",
    inputId: "storybook-small-viewport-composer",
  },
}

export const SmallViewportExpandedCommandSuggestions = {
  decorators: [
    (Story: React.ComponentType) => (
      <div className="flex h-dvh w-full items-end overflow-hidden [&_textarea]:!min-h-[8.5rem]">
        <Story />
      </div>
    ),
  ],
  parameters: {viewport: {defaultViewport: "mobile1"}},
  args: {
    draft: "/",
    inputId: "storybook-expanded-command-composer",
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
    (Story: React.ComponentType) => (
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
