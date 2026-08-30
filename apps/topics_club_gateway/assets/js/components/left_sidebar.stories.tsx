import LeftSidebar from "./left_sidebar.tsx"

const connection = {
  id: "server:1", server_connection_id: 1, name: "Libera Chat", host: "irc.libera.chat", port: 6697, use_tls: true, nickname: "mira",
  channels: [
    {id: "direct:3", buffer_type: "direct_message", channel: "akash", unread_count: 3},
    {id: "channel:1", channel: "#elixir", mention_count: 2},
    {id: "channel:2", channel: "#phoenix", mention_count: 0},
  ],
}

export default {
  title: "Navigation/LeftSidebar",
  component: LeftSidebar,
  decorators: [(Story: React.ComponentType) => <div className="flex h-[44rem] w-60 overflow-hidden rounded-xl border border-white/8 shadow-2xl shadow-black/30"><Story /></div>],
  args: {
    activeChannel: connection.channels[0], activeServer: connection, connections: [connection], currentUser: {email: "mira@example.com"}, mobile: true, notificationDeviceState: {capability: "granted", configured: true, loading: false, subscribed: true}, notificationSavingIds: new Set(), view: "chat",
    onCloseDirectMessage: () => {}, onDiscover: () => {}, onDisconnectServer: () => {}, onEditServer: () => {}, onJoinManualServer: () => {}, onLeaveChannel: () => {}, onLeaveServer: () => {}, onMarkChannelRead: () => {}, onOpenChannelDirectory: () => {}, onReconnectServer: () => {}, onSelectChannel: () => {}, onSelectServer: () => {}, onShowChat: () => {}, onToggleServerNotifications: () => {},
  },
}

export const JoinedChannels = {}
export const DirectMessageUnread = {args: {activeChannel: connection.channels[0]}}
export const ActiveServer = {args: {activeChannel: null, view: "server"}}
export const Empty = {args: {activeChannel: null, activeServer: null, connections: []}}
