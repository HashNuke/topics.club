import ChannelDirectoryFeedback from "./channel_directory_feedback.tsx"

export default {
  title: "Directory/ChannelDirectoryFeedback",
  component: ChannelDirectoryFeedback,
  decorators: [(Story: React.ComponentType) => <div className="w-[52rem] max-w-[calc(100vw-2rem)]"><Story /></div>],
  args: {error: null, joinError: null, onRefresh: () => {}},
}

export const LoadError = {
  args: {error: "The server took too long to return its channel list."},
}

export const JoinError = {
  args: {joinError: "You need an invite to join #private."},
}

export const BothErrors = {
  args: {
    error: "The channel list could not be refreshed.",
    joinError: "The selected channel could not be joined.",
  },
}
