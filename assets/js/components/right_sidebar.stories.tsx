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
