import {FloatingArrow, arrow, offset, shift, useFloating} from "@floating-ui/react"
import React, {cloneElement, useState, type ReactElement} from "react"
import type {AppView, Channel, ConnectionHealth, ServerConnection} from "../types.ts"

type NotificationState = NotificationPermission | "unsupported"

interface TopBarContext {
  activeChannel?: Channel
  activeServer?: ServerConnection
  view: AppView
}

export function topBarCopyFor({activeChannel, activeServer, view}: TopBarContext) {
  if (view === "discover") return {title: "Discover", context: null, subtitle: "Find channels to join."}
  if (view === "directory") return {title: `Channels on ${activeServer?.name || "server"}`, context: null, subtitle: "Browse public conversations and join with one click."}
  if (view === "server") return {title: activeServer?.host || "Server", context: null, subtitle: "Server notices, services, and connection details."}
  return {title: activeChannel?.channel || "Chat", context: activeChannel?.connection?.host ? `on ${activeChannel.connection.host}` : null, subtitle: activeChannel?.topic || "Pick a topic from the sidebar or discover view."}
}

interface TopBarProps extends TopBarContext {
  connectionHealth: ConnectionHealth
  notificationState: NotificationState
  showsUserSidebar: boolean
  onOpenMobileMenu: () => void
  onOpenMobileUsers: () => void
  onRequestNotifications: () => void
  onRetryRealtime: () => void
}

export default function TopBar({activeChannel, activeServer, connectionHealth, notificationState, showsUserSidebar, view, onOpenMobileMenu, onOpenMobileUsers, onRequestNotifications, onRetryRealtime}: TopBarProps) {
  const copy = topBarCopyFor({activeChannel, activeServer, view})
  return (
    <header className="flex h-14 items-center justify-between border-b border-slate-800/80 bg-[#0d1118] px-4">
      <div className="flex min-w-0 items-center gap-3">
        <button className="grid size-9 place-items-center rounded-md border border-slate-700 text-slate-300 transition hover:border-cyan-300 hover:text-white lg:hidden" onClick={onOpenMobileMenu} aria-label="Show channels" type="button"><span className="hero-bars-3 size-5" aria-hidden="true" /></button>
        <div className="min-w-0">
          <div className="flex items-baseline gap-2"><h1 className="truncate text-base font-semibold">{copy.title}</h1>{view !== "server" && copy.context && <span className="hidden text-xs text-slate-500 sm:inline">{copy.context}</span>}</div>
          <p className="truncate text-xs text-slate-500">{copy.subtitle}</p>
        </div>
      </div>
      <div className="flex items-center gap-2">
        <ConnectionHealthIndicator status={connectionHealth} onRetry={onRetryRealtime} />
        {showsUserSidebar && <button className="grid size-9 place-items-center rounded-md border border-slate-700 text-slate-300 transition hover:border-cyan-300 hover:text-white lg:hidden" onClick={onOpenMobileUsers} aria-label="Show users" type="button"><span className="hero-users size-5" aria-hidden="true" /></button>}
        <Tooltip label={notificationLabel(notificationState)}>
          <button id="notification-bell" className={["grid size-9 place-items-center rounded-md border transition", notificationState === "granted" ? "border-emerald-300 bg-emerald-300 text-emerald-950 hover:bg-emerald-200" : "border-slate-700 text-white/75 hover:border-cyan-300 hover:text-white"].join(" ")} onClick={onRequestNotifications} aria-label="Enable browser notifications" type="button"><span className="hero-bell size-4" aria-hidden="true" /></button>
        </Tooltip>
      </div>
    </header>
  )
}

export function ConnectionHealthIndicator({status, onRetry}: {status: ConnectionHealth; onRetry: () => void}) {
  const labels: Record<ConnectionHealth, string> = {connected: "connected", degraded: "degraded", disconnected: "offline", reconnecting: "reconnecting"}
  const label = labels[status]
  const canRetry = ["degraded", "disconnected", "reconnecting"].includes(status)
  return <div className="hidden items-center gap-1.5 rounded-md border border-slate-800 px-2 py-1 text-xs text-slate-400 sm:flex" aria-label={`Connection ${label}`}>
    <span className={["size-1.5 rounded-full", status === "connected" ? "bg-emerald-300" : status === "degraded" || status === "reconnecting" ? "bg-amber-300" : "bg-slate-500"].join(" ")} aria-hidden="true" />
    <span>{label}</span>
    {canRetry && <Tooltip label="Reconnect realtime socket"><button className="ml-1 grid size-5 place-items-center rounded text-slate-300 transition hover:bg-slate-800 hover:text-white" onClick={onRetry} aria-label="Retry realtime connection" type="button"><span className="hero-arrow-path size-3.5" aria-hidden="true" /></button></Tooltip>}
  </div>
}

function notificationLabel(state: NotificationState): string {
  if (state === "granted") return "Browser notifications are enabled for mentions while this tab is hidden."
  if (state === "denied") return "Notifications are blocked in your browser settings."
  if (state === "unsupported") return "This browser does not support notifications."
  return "Enable browser notifications for mentions."
}

type TooltipChildProps = React.HTMLAttributes<HTMLElement> & {ref?: React.Ref<HTMLElement>}

function Tooltip({children, label}: {children: ReactElement<TooltipChildProps>; label: string}) {
  const [open, setOpen] = useState(false)
  const [arrowEl, setArrowEl] = useState<SVGSVGElement | null>(null)
  const {refs, floatingStyles, context} = useFloating({open, onOpenChange: setOpen, placement: "bottom", middleware: [offset(8), shift(), arrow({element: arrowEl})]})
  return <>{cloneElement(children, {ref: refs.setReference, onMouseEnter: () => setOpen(true), onMouseLeave: () => setOpen(false), onFocus: () => setOpen(true), onBlur: () => setOpen(false)})}{open && <div ref={refs.setFloating} style={floatingStyles} className="z-50 max-w-64 rounded-md border border-slate-700 bg-slate-950 px-2 py-1 text-xs text-slate-200 shadow-xl" role="tooltip">{label}<FloatingArrow ref={setArrowEl} context={context} className="fill-slate-700" /></div>}</>
}
