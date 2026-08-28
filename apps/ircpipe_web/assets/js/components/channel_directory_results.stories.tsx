import ChannelDirectoryResults from "./channel_directory_results.tsx"

const channels = [
  {channel: "#elixir", users: 426, topic: "Phoenix, OTP, and production Elixir help."},
  {channel: "#phoenix", users: 188, topic: "Phoenix Framework and LiveView."},
  {channel: "#quiet", users: 1, topic: null},
]

export default {
  title: "Directory/ChannelDirectoryResults",
  component: ChannelDirectoryResults,
  decorators: [(Story: React.ComponentType) => <div className="w-[52rem] max-w-[calc(100vw-2rem)]"><Story /></div>],
  args: {
    channels,
    directory: {status: "ready", joiningChannel: null},
    onJoinChannel: () => {},
    serverName: "Libera Chat",
  },
}

export const Ready = {}

export const Joining = {
  args: {directory: {status: "ready", joiningChannel: "#phoenix"}},
}

export const Loading = {
  args: {channels: [], directory: {status: "loading"}},
}

export const Empty = {
  args: {channels: []},
}

export const MobileWidth = {
  decorators: [(Story: React.ComponentType) => <div className="w-80 max-w-full"><Story /></div>],
}
