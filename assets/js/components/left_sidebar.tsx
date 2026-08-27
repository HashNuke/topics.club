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
  const idNamespace = mobile ? "mobile-sidebar" : "desktop-sidebar"

  return (
    <aside className={["min-h-0 border-r border-white/6 bg-[var(--app-sidebar)]", mobile ? "flex min-h-0 flex-1 flex-col border-r-0" : "hidden lg:flex lg:flex-col"].join(" ")}>
      <div className="flex h-14 items-center justify-between border-b border-white/6 px-3">
        <button className="group flex items-center text-left focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-cyan-300/70" onClick={onShowChat} type="button">
          <AppMark small />
        </button>
        <button id={`${idNamespace}-add-server-button`} className="grid size-7 place-items-center rounded-lg border border-white/8 bg-white/3 text-slate-400 transition duration-200 hover:border-cyan-300/40 hover:bg-cyan-300/10 hover:text-cyan-200 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-cyan-300/70" onClick={() => setManualOpen(true)} aria-label="Join another server" type="button">
          <span className="hero-plus size-4" aria-hidden="true" />
        </button>
      </div>
      <div className="border-b border-white/6 p-2.5">
        <button id={`${idNamespace}-discover-channels-button`} className="group flex h-9 w-full items-center gap-2 rounded-lg border border-white/7 bg-white/3 px-2.5 text-left text-sm font-medium text-slate-300 transition duration-200 hover:border-cyan-300/25 hover:bg-white/6 hover:text-white focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-cyan-300/70" onClick={onDiscover} type="button">
          <span className="hero-magnifying-glass size-4 text-slate-500 transition group-hover:text-cyan-300" aria-hidden="true" />
          <span className="flex-1">Discover</span>
          <span className="text-[10px] uppercase tracking-[0.12em] text-slate-600">Browse</span>
        </button>
      </div>
      <nav className="app-scrollbar min-h-0 flex-1 overflow-y-auto px-2.5 py-3" aria-label="Joined topics">
        {connections.map((connection) => (
          <SidebarConnection
            key={connection.id}
            activeChannel={activeChannel}
            activeServer={activeServer}
            connection={connection}
            idNamespace={idNamespace}
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
      <div className="border-t border-white/6 p-2.5">
        <div className="flex items-center gap-2.5 rounded-lg border border-white/5 bg-white/3 p-1.5">
          <div className="grid size-8 place-items-center rounded-lg bg-gradient-to-br from-cyan-200 to-cyan-400 text-xs font-bold text-cyan-950 shadow-sm shadow-black/20">{currentUser.email.slice(0, 2).toUpperCase()}</div>
          <div className="min-w-0">
            <div className="truncate text-sm font-medium text-slate-200">{currentUser.email.split("@")[0]}</div>
            <div className="flex items-center gap-1.5 text-[11px] text-slate-500"><span className="size-1.5 rounded-full bg-emerald-300" aria-hidden="true" />connected</div>
          </div>
        </div>
      </div>
      {manualOpen && <ManualJoinDialog onClose={() => setManualOpen(false)} onJoin={(form) => { onJoinManualServer(form); setManualOpen(false) }} />}
      {editingServer && <EditServerDialog server={editingServer} onClose={() => setEditingServer(null)} onSave={(form) => { onUpdateServer?.(editingServer, form); setEditingServer(null) }} />}
      {leavingServer && <LeaveServerDialog server={leavingServer} onClose={() => setLeavingServer(null)} onConfirm={() => { onLeaveServer?.(leavingServer); setLeavingServer(null) }} />}
    </aside>
  )
}
