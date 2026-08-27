import {useEffect, useRef} from "react"
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

export const OpenInsideScrollingSidebar = {
  render: () => <OpenScrollingSidebarStory />,
}

function OpenScrollingSidebarStory() {
  const sidebarRef = useRef<HTMLDivElement | null>(null)

  useEffect(() => {
    sidebarRef.current?.querySelector<HTMLButtonElement>("button")?.click()
  }, [])

  return (
    <div ref={sidebarRef} className="h-32 w-56 overflow-y-auto rounded-md border border-slate-800 bg-[#0f131b] p-3">
      <div className="h-48 pt-20">
        <ChannelActionMenu channel={{id: "channel:1", buffer_type: "channel", channel_membership_id: 1, channel: "#elixir", mention_notifications_enabled: true, notification_preference_revision: 0}} onCopyChannel={() => {}} onLeaveChannel={() => {}} onMarkRead={() => {}} />
      </div>
    </div>
  )
}
