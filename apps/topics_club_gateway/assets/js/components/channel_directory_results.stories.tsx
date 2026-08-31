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
    directory: {status: "ready", joiningChannel: null, page: 2, pageSize: 25, totalChannels: 53, totalPages: 3},
    onJoinChannel: () => {},
    onPageChange: () => {},
    serverName: "Libera Chat",
  },
}

export const Ready = {}

export const Joining = {
  args: {directory: {status: "ready", joiningChannel: "#phoenix", page: 2, pageSize: 25, totalChannels: 53, totalPages: 3}},
}

export const Loading = {
  args: {channels: [], directory: {status: "loading", page: 1, pageSize: 25, totalChannels: 0, totalPages: 1}},
}

export const Empty = {
  args: {channels: [], directory: {status: "ready", joiningChannel: null, page: 1, pageSize: 25, totalChannels: 0, totalPages: 1}},
}

export const MobileWidth = {
  decorators: [(Story: React.ComponentType) => <div className="w-80 max-w-full"><Story /></div>],
}
