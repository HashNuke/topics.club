import {ChannelActionMenu, ServerActionMenu} from "./sidebar_action_menus.tsx"

export default {
  title: "Navigation/SidebarActionMenus",
  decorators: [(Story) => <div className="flex h-64 w-64 justify-center pt-12"><Story /></div>],
}

export const ChannelActions = {
  render: () => <ChannelActionMenu channel={{channel: "#elixir"}} onCopyChannel={() => {}} onLeaveChannel={() => {}} onMarkRead={() => {}} />,
}

export const ServerActions = {
  render: () => <ServerActionMenu server={{name: "Libera Chat"}} onDisconnect={() => {}} onEdit={() => {}} onLeave={() => {}} onReconnect={() => {}} />,
}
