import ChannelDirectoryPane from "./channel_directory_pane.jsx"

const channels = [
  {channel: "#elixir", users: 426, topic: "Phoenix, OTP, releases, and production Elixir help."},
  {channel: "#phoenix", users: 188, topic: "Phoenix Framework, LiveView, and web UI questions."},
  {channel: "#music", users: 72, topic: "Albums, instruments, and live shows."},
]

export default {
  title: "Directory/ChannelDirectoryPane",
  component: ChannelDirectoryPane,
  decorators: [
    (Story) => (
      <div className="h-[42rem] w-[64rem] max-w-[calc(100vw-2rem)] overflow-hidden border border-slate-800">
        <Story />
      </div>
    ),
  ],
  args: {
    directory: {channels, joiningChannel: null, status: "ready"},
    onJoinChannel: () => {},
    onRefresh: () => {},
    server: {id: "server:42", name: "Libera Chat"},
  },
}

export const Ready = {}

export const Loading = {
  args: {directory: {channels: [], status: "loading"}},
}

export const Empty = {
  args: {directory: {channels: [], status: "ready"}},
}

export const LoadError = {
  args: {
    directory: {
      channels: [],
      error: "The server took too long to return its channel list.",
      status: "ready",
    },
  },
}

export const JoiningChannel = {
  args: {directory: {channels, joiningChannel: "#phoenix", status: "ready"}},
}

export const MobileWidth = {
  decorators: [
    (Story) => (
      <div className="h-[42rem] w-80 max-w-full overflow-hidden border border-slate-800">
        <Story />
      </div>
    ),
  ],
}
