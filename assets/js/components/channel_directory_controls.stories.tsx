import {useState} from "react"
import ChannelDirectoryControls from "./channel_directory_controls.tsx"
import type {ComponentProps} from "react"

type ControlsArgs = ComponentProps<typeof ChannelDirectoryControls>

function InteractiveControls(args: ControlsArgs) {
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
  render: (args: ControlsArgs) => <InteractiveControls {...args} />,
  decorators: [(Story: React.ComponentType) => <div className="w-[52rem] max-w-[calc(100vw-2rem)]"><Story /></div>],
  args: {manualChannel: "", query: ""},
}

export const Empty = {}

export const Filled = {
  args: {manualChannel: "#phoenix", query: "elixir"},
}

export const MobileWidth = {
  decorators: [(Story: React.ComponentType) => <div className="w-80 max-w-full"><Story /></div>],
}
