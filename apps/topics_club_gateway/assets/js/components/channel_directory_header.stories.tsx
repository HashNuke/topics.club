import ChannelDirectoryHeader from "./channel_directory_header.tsx"

export default {
  title: "Directory/ChannelDirectoryHeader",
  component: ChannelDirectoryHeader,
  decorators: [(Story: React.ComponentType) => <div className="w-[52rem] max-w-[calc(100vw-2rem)]"><Story /></div>],
  args: {
    serverName: "Libera Chat",
  },
}

export const Ready = {}

export const MobileWidth = {
  decorators: [(Story: React.ComponentType) => <div className="w-80 max-w-full"><Story /></div>],
}
