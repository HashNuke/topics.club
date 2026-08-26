import React, {useState} from "react"
import AppMark from "./app_mark.tsx"
import {EditServerDialog, LeaveServerDialog, ManualJoinDialog} from "./server_dialogs.tsx"
import SidebarConnection from "./sidebar_connection.tsx"
import type {EditServerForm, ManualServerForm} from "../hooks/use_server_connections.ts"
import type {AppView, Channel, CurrentUser, ServerConnection} from "../types.ts"
import type {NotificationDeviceState} from "../browser_notifications.ts"

export interface LeftSidebarProps {
  activeChannel?: Channel
  activeServer?: ServerConnection
  connections: ServerConnection[]
  currentUser: CurrentUser
  notificationDeviceState: NotificationDeviceState
  notificationSavingIds: Set<string>
  mobile?: boolean
  view: AppView
  onDiscover: () => void
  onDisconnectServer: (server: ServerConnection) => void
  onCloseDirectMessage: (channel: Channel) => void
  onJoinManualServer: (form: ManualServerForm) => void
  onLeaveChannel: (channel: Channel) => void
  onLeaveServer: (server: ServerConnection) => void
  onMarkChannelRead: (channel: Channel) => void
  onOpenChannelDirectory: (server: ServerConnection) => void
  onReconnectServer: (server: ServerConnection) => void
  onSelectChannel: (channel: Channel) => void
  onSelectServer: (server: ServerConnection) => void
  onToggleServerNotifications: (server: ServerConnection) => void
  onShowChat: () => void
  onUpdateServer: (server: ServerConnection, form: EditServerForm) => void
}

export default function LeftSidebar(props: LeftSidebarProps) {
  const {activeChannel, activeServer, connections, currentUser, mobile = false, notificationDeviceState, notificationSavingIds, view, onCloseDirectMessage, onDiscover, onDisconnectServer, onJoinManualServer, onLeaveChannel, onLeaveServer, onMarkChannelRead, onOpenChannelDirectory, onReconnectServer, onSelectChannel, onSelectServer, onShowChat, onToggleServerNotifications, onUpdateServer} = props
  const [manualOpen, setManualOpen] = useState(false)
  const [editingServer, setEditingServer] = useState<ServerConnection | null>(null)
  const [leavingServer, setLeavingServer] = useState<ServerConnection | null>(null)

  return (
    <aside className={["min-h-0 border-r border-slate-800/80 bg-[#0f131b]", mobile ? "flex min-h-0 flex-1 flex-col border-r-0" : "hidden lg:flex lg:flex-col"].join(" ")}>
      <div className="flex h-14 items-center justify-between border-b border-slate-800/80 px-4">
        <button className="flex items-center gap-2 text-left" onClick={onShowChat} type="button">
          <AppMark small />
          <span className="font-semibold tracking-tight">topics.club</span>
        </button>
        <button id="add-server-button" className="grid size-8 place-items-center rounded-md border border-slate-700 text-slate-300 transition hover:border-cyan-300 hover:text-white" onClick={() => setManualOpen(true)} aria-label="Join another server" type="button">
          <span className="hero-plus size-4" aria-hidden="true" />
        </button>
      </div>
      <div className="space-y-2 border-b border-slate-800/80 p-3">
        <button id="discover-channels-button" className="flex w-full items-center justify-between rounded-md border border-slate-700/80 bg-slate-900/70 px-3 py-2 text-left text-sm text-slate-200 transition hover:border-cyan-300" onClick={onDiscover} type="button">
          <span>Discover</span>
          <span className="hero-magnifying-glass size-4 text-slate-500" aria-hidden="true" />
        </button>
      </div>
      <nav className="min-h-0 flex-1 overflow-y-auto px-3 py-3" aria-label="Joined topics">
        {connections.map((connection) => (
          <SidebarConnection
            key={connection.id}
            activeChannel={activeChannel}
            activeServer={activeServer}
            connection={connection}
            notificationDeviceState={notificationDeviceState}
            notificationSavingIds={notificationSavingIds}
            onCloseDirectMessage={onCloseDirectMessage}
            onDisconnectServer={onDisconnectServer}
            onEditServer={setEditingServer}
            onLeaveChannel={onLeaveChannel}
            onLeaveServer={setLeavingServer}
            onMarkChannelRead={onMarkChannelRead}
            onOpenChannelDirectory={onOpenChannelDirectory}
            onReconnectServer={onReconnectServer}
            onSelectChannel={onSelectChannel}
            onSelectServer={onSelectServer}
            onToggleServerNotifications={onToggleServerNotifications}
            view={view}
          />
        ))}
      </nav>
      <div className="border-t border-slate-800/80 p-3">
        <div className="flex items-center gap-3 rounded-md bg-slate-900/70 p-2">
          <div className="grid size-9 place-items-center rounded-md bg-emerald-300 text-sm font-bold text-emerald-950">{currentUser.email.slice(0, 2).toUpperCase()}</div>
          <div className="min-w-0">
            <div className="truncate text-sm font-medium">{currentUser.email.split("@")[0]}</div>
            <div className="text-xs text-emerald-300">connected</div>
          </div>
        </div>
      </div>
      {manualOpen && <ManualJoinDialog onClose={() => setManualOpen(false)} onJoin={(form) => { onJoinManualServer(form); setManualOpen(false) }} />}
      {editingServer && <EditServerDialog server={editingServer} onClose={() => setEditingServer(null)} onSave={(form) => { onUpdateServer?.(editingServer, form); setEditingServer(null) }} />}
      {leavingServer && <LeaveServerDialog server={leavingServer} onClose={() => setLeavingServer(null)} onConfirm={() => { onLeaveServer?.(leavingServer); setLeavingServer(null) }} />}
    </aside>
  )
}
