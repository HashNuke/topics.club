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
    <section className="mb-5">
      <div className={[
        "mb-2 flex w-full items-center gap-1 rounded-md pr-1 text-xs font-semibold uppercase tracking-[0.16em] transition",
        activeServer?.id === connection.id && view === "server" ? "bg-slate-800 text-cyan-200" : "text-slate-500 hover:bg-slate-800/70 hover:text-slate-300",
      ].join(" ")}>
        <button className="flex min-w-0 flex-1 items-center gap-2 px-1 py-1 text-left" onClick={() => onSelectServer(connection)} type="button">
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
          className="grid size-7 shrink-0 place-items-center rounded text-slate-500 transition hover:bg-slate-700 hover:text-cyan-200 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-cyan-300/70"
          onClick={() => onOpenChannelDirectory?.(connection)}
          aria-label={`Browse channels on ${connection.name}`}
          type="button"
        >
          <span className="hero-plus size-3.5" aria-hidden="true" />
        </button>
        <ServerActionMenu server={connection} onDisconnect={() => onDisconnectServer?.(connection)} onEdit={() => onEditServer(connection)} onLeave={() => onLeaveServer(connection)} onReconnect={() => onReconnectServer?.(connection)} />
      </div>
      <div className="space-y-1">
        {connection.channels.map((channel) => (
          <div key={channel.id} className={[
            "group flex w-full items-center gap-1 rounded-md border pr-1 text-sm outline-none transition focus-within:border-cyan-300/50",
            activeChannel?.id === channel.id ? "border border-cyan-300/30 bg-cyan-300/10 text-cyan-100" : "border-transparent text-white/75 hover:bg-slate-800/80 hover:text-white",
          ].join(" ")}>
            <button className="flex min-w-0 flex-1 items-center gap-2 px-2 py-2 text-left" onClick={() => onSelectChannel(channel)} type="button">
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
