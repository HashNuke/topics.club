import RightSidebar from "./right_sidebar.tsx"

const users = [
  {nick: "mira", role: "owner", status: "online"},
  {nick: "akash", role: "op", status: "online"},
  {nick: "robin", role: "voice", status: "online"},
  ...Array.from({length: 12}, (_, index) => ({nick: `member_${index + 1}`, role: "user", status: "online"})),
  {nick: "lena", role: "user", status: "away"},
]

export default {
  title: "People/RightSidebar",
  component: RightSidebar,
  decorators: [
    (Story: React.ComponentType) => (
      <div className="h-[42rem] w-72 overflow-hidden border border-slate-800">
        <Story />
      </div>
    ),
  ],
  args: {
    activeChannel: {channel: "#elixir"},
    mobile: true,
    users,
    onSetDirectMessageBlocked: () => {},
  },
}

export const GroupedPeople = {}

export const Empty = {
  args: {users: []},
}

export const AwayOnly = {
  args: {
    users: [
      {nick: "mira", role: "user", status: "away"},
      {nick: "akash", role: "voice", status: "away"},
    ],
  },
}

export const NoActiveChannel = {
  args: {activeChannel: null},
}

export const DirectMessagePeer = {
  args: {
    activeChannel: {
      id: "direct:8",
      buffer_type: "direct_message",
      channel: "akash",
      topic: "on irc.libera.chat",
      account: "akash-account",
      hostmask: "akash!user@example.net",
      blocked: false,
    },
    users: [],
  },
}

export const BlockedDirectMessagePeer = {
  args: {
    ...DirectMessagePeer.args,
    activeChannel: {...DirectMessagePeer.args.activeChannel, blocked: true},
  },
}
