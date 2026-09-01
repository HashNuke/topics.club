import React from "react"
import {
  ChannelActionMenu,
  DirectMessageActionMenu,
  ServerActionMenu,
} from "./sidebar_action_menus.tsx"
import type {AppView, Channel, ServerConnection} from "../types.ts"
import type {NotificationDeviceState} from "../browser_notifications.ts"
import {notificationControlState} from "../push_notifications.ts"
import NotificationBell from "./notification_bell.tsx"

export interface SidebarConnectionProps {
  activeChannel?: Channel
  activeServer?: ServerConnection
  connection: ServerConnection
  idNamespace?: string
  notificationDeviceState: NotificationDeviceState
  notificationSavingIds: Set<string>
  onDisconnectServer?: (server: ServerConnection) => void
  onCloseDirectMessage?: (channel: Channel) => void
  onEditServer: (server: ServerConnection) => void
  onLeaveChannel?: (channel: Channel) => void
  onLeaveServer: (server: ServerConnection) => void
  onMarkChannelRead?: (channel: Channel) => void
  onOpenChannelDirectory?: (server: ServerConnection) => void
  onReconnectServer?: (server: ServerConnection) => void
  onSelectChannel: (channel: Channel) => void
  onSelectServer: (server: ServerConnection) => void
  onToggleServerNotifications: (server: ServerConnection) => void
  view: AppView
}

export default function SidebarConnection(props: SidebarConnectionProps) {
  const {activeChannel, activeServer, connection, idNamespace = "sidebar", notificationDeviceState, notificationSavingIds, onCloseDirectMessage, onDisconnectServer, onEditServer, onLeaveChannel, onLeaveServer, onMarkChannelRead, onOpenChannelDirectory, onReconnectServer, onSelectChannel, onSelectServer, onToggleServerNotifications, view} = props
  return (
    <section className="mb-3.5">
      <div className={[
        "mb-1 flex w-full items-center gap-0.5 rounded-lg pr-0.5 text-[11px] font-semibold uppercase tracking-[0.13em] transition duration-200",
        activeServer?.id === connection.id && view === "server" ? "bg-cyan-300/10 text-cyan-200" : "text-slate-500 hover:bg-white/5 hover:text-slate-300",
      ].join(" ")}>
        <button aria-current={activeServer?.id === connection.id && view === "server" ? "page" : undefined} className="flex min-w-0 flex-1 items-center gap-2 px-1.5 py-1.5 text-left" onClick={() => onSelectServer(connection)} type="button">
          <span className="size-1.5 rounded-full bg-emerald-400" aria-hidden="true" />
          <span className="truncate">{connection.name}</span>
        </button>
        <NotificationBell
          compact
          id={`${idNamespace}-server-notification-bell-${connection.server_connection_id}`}
          loading={notificationDeviceState.loading || notificationSavingIds.has(connection.id)}
          onToggle={() => onToggleServerNotifications(connection)}
          scopeLabel={connection.name || connection.host}
          state={notificationControlState(notificationDeviceState, connection.mention_notifications_enabled)}
        />
        <button
          id={`${idNamespace}-browse-channels-${connection.server_connection_id}`}
          className="grid size-6 shrink-0 place-items-center rounded-md text-slate-500 transition hover:bg-white/7 hover:text-cyan-200 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-cyan-300/70"
          onClick={() => onOpenChannelDirectory?.(connection)}
          aria-label={`Browse channels on ${connection.name}`}
          type="button"
        >
          <span className="hero-plus size-3.5" aria-hidden="true" />
        </button>
        <ServerActionMenu server={connection} onDisconnect={() => onDisconnectServer?.(connection)} onEdit={() => onEditServer(connection)} onLeave={() => onLeaveServer(connection)} onReconnect={() => onReconnectServer?.(connection)} />
      </div>
      <div className="space-y-0.5">
        {connection.channels.map((channel) => (
          <div key={channel.id} className={[
            "group flex w-full items-center gap-0.5 rounded-lg border pr-0.5 text-[13px] outline-none transition duration-200 focus-within:border-cyan-300/50",
            view === "chat" && activeChannel?.id === channel.id ? "border-cyan-300/25 bg-cyan-300/10 text-cyan-100 shadow-[inset_2px_0_0_var(--color-cyan-300)]" : "border-transparent text-slate-300 hover:bg-white/5 hover:text-white",
          ].join(" ")}>
            <button aria-current={view === "chat" && activeChannel?.id === channel.id ? "page" : undefined} className="flex min-w-0 flex-1 items-center gap-2 px-2 py-1.5 text-left" onClick={() => onSelectChannel(channel)} type="button">
              {channel.buffer_type === "direct_message" && (
                <span className="hero-user size-3.5 shrink-0 text-slate-500" aria-hidden="true" />
              )}
              <span className="min-w-0 flex-1 truncate">{channel.channel}</span>
              <UnreadBadge channel={channel} />
            </button>
            {channel.buffer_type === "direct_message" ? (
              <DirectMessageActionMenu
                channel={channel}
                onClose={() => onCloseDirectMessage?.(channel)}
              />
            ) : (
              <ChannelActionMenu channel={channel} onCopyChannel={() => navigator.clipboard?.writeText(channel.channel)} onLeaveChannel={() => onLeaveChannel?.(channel)} onMarkRead={() => onMarkChannelRead?.(channel)} />
            )}
          </div>
        ))}
      </div>
    </section>
  )
}

function UnreadBadge({channel}: {channel: Channel}) {
  const unreadCount = channel.unread_count || 0
  const mentionCount = channel.mention_count || 0

  if (unreadCount > 0) {
    const location = channel.buffer_type === "direct_message" ? "from" : "in"

    return (
      <span
        className="min-w-5 rounded-full bg-rose-400 px-1.5 text-center text-xs font-semibold text-rose-950"
        aria-label={`${unreadCount} unread ${unreadCount === 1 ? "message" : "messages"} ${location} ${channel.channel}`}
      >
        {unreadCount}
      </span>
    )
  }

  if (mentionCount === 0) return null

  return (
    <span
      className="min-w-5 rounded-full bg-rose-400 px-1.5 text-center text-xs font-semibold text-rose-950"
      aria-label={`${mentionCount} unread ${mentionCount === 1 ? "mention" : "mentions"} in ${channel.channel}`}
    >
      {mentionCount}
    </span>
  )
}
