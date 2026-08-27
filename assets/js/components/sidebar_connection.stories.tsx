import SidebarConnection from "./sidebar_connection.tsx"

const connection = {
  id: "server:1",
  server_connection_id: 1,
  name: "Libera Chat",
  channels: [
    {id: "direct:3", buffer_type: "direct_message", channel: "akash", unread_count: 3},
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
    notificationDeviceState: {capability: "granted", configured: true, loading: false, subscribed: true}, notificationSavingIds: new Set(),
    onCloseDirectMessage: () => {}, onDisconnectServer: () => {}, onEditServer: () => {}, onLeaveChannel: () => {}, onLeaveServer: () => {}, onMarkChannelRead: () => {}, onOpenChannelDirectory: () => {}, onReconnectServer: () => {}, onSelectChannel: () => {}, onSelectServer: () => {}, onToggleServerNotifications: () => {},
  },
}

export const ActiveChannel = {}
export const ActiveDirectMessage = {args: {activeChannel: connection.channels[0]}}
export const DirectMessageRead = {args: {connection: {...connection, channels: connection.channels.map((item) => item.id === "direct:3" ? {...item, unread_count: 0} : item)}}}
export const ChannelUnread = {args: {connection: {...connection, channels: connection.channels.map((item) => item.id === "channel:2" ? {...item, unread_count: 4} : item)}}}
export const ActiveServer = {args: {activeChannel: null, view: "server"}}
export const NoChannels = {args: {connection: {...connection, channels: []}}}
