import ChannelDirectoryPane from "./channel_directory_pane.tsx"

const channels = [
  {channel: "#elixir", users: 426, topic: "Phoenix, OTP, releases, and production Elixir help."},
  {channel: "#phoenix", users: 188, topic: "Phoenix Framework, LiveView, and web UI questions."},
  {channel: "#music", users: 72, topic: "Albums, instruments, and live shows."},
]

export default {
  title: "Directory/ChannelDirectoryPane",
  component: ChannelDirectoryPane,
  decorators: [
    (Story: React.ComponentType) => (
      <div className="h-[42rem] w-[64rem] max-w-[calc(100vw-2rem)] overflow-hidden border border-slate-800">
        <Story />
      </div>
    ),
  ],
  args: {
    directory: {channels, joiningChannel: null, page: 2, pageSize: 25, query: "", serverId: "server:42", status: "ready", totalChannels: 53, totalPages: 3},
    onJoinChannel: () => {},
    onPageChange: () => {},
    onSearch: () => {},
    server: {id: "server:42", name: "Libera Chat"},
  },
}

export const Ready = {}

export const Loading = {
  args: {directory: {channels: [], page: 1, pageSize: 25, query: "", serverId: "server:42", status: "loading", totalChannels: 0, totalPages: 1}},
}

export const Empty = {
  args: {directory: {channels: [], page: 1, pageSize: 25, query: "obscure", serverId: "server:42", status: "ready", totalChannels: 0, totalPages: 1}},
}

export const LoadError = {
  args: {
    directory: {
      channels: [],
      error: "The server took too long to return its channel list.",
      page: 1,
      pageSize: 25,
      query: "",
      serverId: "server:42",
      status: "error",
      totalChannels: 0,
      totalPages: 1,
    },
  },
}

export const JoiningChannel = {
  args: {directory: {channels, joiningChannel: "#phoenix", page: 1, pageSize: 25, query: "", serverId: "server:42", status: "ready", totalChannels: 3, totalPages: 1}},
}

export const MobileWidth = {
  decorators: [
    (Story: React.ComponentType) => (
      <div className="h-[42rem] w-80 max-w-full overflow-hidden border border-slate-800">
        <Story />
      </div>
    ),
  ],
}
