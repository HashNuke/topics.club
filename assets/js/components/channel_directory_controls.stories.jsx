import {useState} from "react"
import ChannelDirectoryControls from "./channel_directory_controls.tsx"

function InteractiveControls(args) {
  const [query, setQuery] = useState(args.query)
  const [manualChannel, setManualChannel] = useState(args.manualChannel)

  return (
    <ChannelDirectoryControls
      {...args}
      manualChannel={manualChannel}
      onJoinManualChannel={(event) => event.preventDefault()}
      onUpdateManualChannel={setManualChannel}
      onUpdateQuery={setQuery}
      query={query}
    />
  )
}

export default {
  title: "Directory/ChannelDirectoryControls",
  component: ChannelDirectoryControls,
  render: (args) => <InteractiveControls {...args} />,
  decorators: [(Story) => <div className="w-[52rem] max-w-[calc(100vw-2rem)]"><Story /></div>],
  args: {manualChannel: "", query: ""},
}

export const Empty = {}

export const Filled = {
  args: {manualChannel: "#phoenix", query: "elixir"},
}

export const MobileWidth = {
  decorators: [(Story) => <div className="w-80 max-w-full"><Story /></div>],
}
