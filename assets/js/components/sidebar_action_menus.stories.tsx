import {ChannelActionMenu, ServerActionMenu} from "./sidebar_action_menus.tsx"

export default {
  title: "Navigation/SidebarActionMenus",
  decorators: [(Story: React.ComponentType) => <div className="flex h-64 w-64 justify-center pt-12"><Story /></div>],
}

export const ChannelActions = {
  render: () => <ChannelActionMenu channel={{id: "channel:1", channel: "#elixir"}} onCopyChannel={() => {}} onLeaveChannel={() => {}} onMarkRead={() => {}} />,
}

export const ServerActions = {
  render: () => <ServerActionMenu server={{id: "server:1", name: "Libera Chat", host: "irc.libera.chat", channels: []}} onDisconnect={() => {}} onEdit={() => {}} onLeave={() => {}} onReconnect={() => {}} />,
}
