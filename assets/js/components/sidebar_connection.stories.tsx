import SidebarConnection from "./sidebar_connection.tsx"

const connection = {
  id: "server:1",
  server_connection_id: 1,
  name: "Libera Chat",
  channels: [
    {id: "channel:1", channel: "#elixir", mention_count: 2},
    {id: "channel:2", channel: "#phoenix", mention_count: 0},
  ],
}

export default {
  title: "Navigation/SidebarConnection",
  component: SidebarConnection,
  decorators: [(Story: React.ComponentType) => <div className="w-72 max-w-full p-3"><Story /></div>],
  args: {
    activeChannel: connection.channels[0], activeServer: connection, connection, view: "chat",
    onDisconnectServer: () => {}, onEditServer: () => {}, onLeaveChannel: () => {}, onLeaveServer: () => {}, onMarkChannelRead: () => {}, onOpenChannelDirectory: () => {}, onReconnectServer: () => {}, onSelectChannel: () => {}, onSelectServer: () => {},
  },
}

export const ActiveChannel = {}
export const ActiveServer = {args: {activeChannel: null, view: "server"}}
export const NoChannels = {args: {connection: {...connection, channels: []}}}
