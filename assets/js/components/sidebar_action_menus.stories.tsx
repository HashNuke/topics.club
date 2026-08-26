import {ChannelActionMenu, DirectMessageActionMenu, ServerActionMenu} from "./sidebar_action_menus.tsx"

export default {
  title: "Navigation/SidebarActionMenus",
  decorators: [(Story: React.ComponentType) => <div className="flex h-64 w-64 justify-center pt-12"><Story /></div>],
}

export const ChannelActions = {
  render: () => <ChannelActionMenu channel={{id: "channel:1", buffer_type: "channel", channel_membership_id: 1, channel: "#elixir", mention_notifications_enabled: true, notification_preference_revision: 0}} onCopyChannel={() => {}} onLeaveChannel={() => {}} onMarkRead={() => {}} />,
}

export const ServerActions = {
  render: () => <ServerActionMenu server={{id: "server:1", server_connection_id: 1, name: "Libera Chat", host: "irc.libera.chat", mention_notifications_enabled: true, notification_preference_revision: 0, channels: []}} onDisconnect={() => {}} onEdit={() => {}} onLeave={() => {}} onReconnect={() => {}} />,
}

export const DirectMessageActions = {
  render: () => <DirectMessageActionMenu channel={{id: "direct:8", buffer_type: "direct_message", direct_message_thread_id: 8, direct_message_revision: 1, channel: "akash", blocked: false}} onClose={() => {}} />,
}
