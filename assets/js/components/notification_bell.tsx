import React from "react"

export type NotificationControlKind = "enabled" | "disabled" | "available" | "unavailable"

export interface NotificationControlState {
  kind: NotificationControlKind
  reason?: string
}

export interface NotificationBellProps {
  compact?: boolean
  id: string
  loading?: boolean
  onToggle: () => void
  scopeLabel: string
  state: NotificationControlState
}

export default function NotificationBell({compact = false, id, loading = false, onToggle, scopeLabel, state}: NotificationBellProps) {
  const unavailable = state.kind === "unavailable"
  const copy = notificationCopy(scopeLabel, state)

  return (
    <span className="group/notification relative inline-grid shrink-0 place-items-center">
      <button
        id={id}
        className={[
          "relative grid shrink-0 place-items-center rounded-md border transition duration-150 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-cyan-300/70",
          compact ? "size-7" : "size-9",
          state.kind === "enabled" && "border-emerald-300/70 bg-emerald-300 text-emerald-950 shadow-[0_0_0_1px_rgba(110,231,183,0.08)] hover:bg-emerald-200",
          state.kind === "disabled" && "border-slate-700 bg-slate-900/60 text-slate-400 hover:border-cyan-300/70 hover:text-white",
          state.kind === "available" && "border-cyan-300/50 bg-cyan-300/5 text-cyan-200 hover:-translate-y-px hover:border-cyan-200 hover:bg-cyan-300/10 hover:text-white",
          unavailable && "cursor-not-allowed border-slate-800 bg-slate-950/30 text-slate-600",
          loading && "cursor-wait",
        ].filter(Boolean).join(" ")}
        disabled={unavailable || loading}
        onClick={onToggle}
        aria-label={copy.action}
        aria-describedby={`${id}-tooltip`}
        type="button"
      >
        {loading
          ? <span className="hero-arrow-path size-4 animate-spin" aria-hidden="true" />
          : <span className={[
            state.kind === "enabled" ? "hero-bell" : state.kind === "disabled" || unavailable ? "hero-bell-slash" : "hero-bell-alert",
            compact ? "size-3.5" : "size-4",
          ].join(" ")} aria-hidden="true" />}
        {state.kind === "available" && !loading && <span className="absolute right-1 top-1 size-1.5 rounded-full bg-cyan-300 ring-2 ring-[#0d1118]" aria-hidden="true" />}
        {unavailable && !loading && <span className="hero-lock-closed absolute -bottom-0.5 -right-0.5 size-2.5 rounded-full bg-slate-950 text-slate-500" aria-hidden="true" />}
      </button>
      <span
        id={`${id}-tooltip`}
        className="pointer-events-none absolute right-0 top-full z-50 mt-2 hidden w-max max-w-64 rounded-md border border-slate-700 bg-slate-950 px-2.5 py-1.5 text-left text-xs font-normal normal-case tracking-normal text-slate-200 shadow-xl group-hover/notification:block group-focus-within/notification:block"
        role="tooltip"
      >
        {copy.tooltip}
      </span>
    </span>
  )
}

function notificationCopy(scopeLabel: string, state: NotificationControlState): {action: string; tooltip: string} {
  if (state.kind === "enabled") {
    return {action: `Mute mention notifications for ${scopeLabel}`, tooltip: `Mention notifications are on for ${scopeLabel}.`}
  }

  if (state.kind === "disabled") {
    return {action: `Enable mention notifications for ${scopeLabel}`, tooltip: state.reason || `Mention notifications are muted for ${scopeLabel}.`}
  }

  if (state.kind === "available") {
    return {action: `Set up mention notifications for ${scopeLabel}`, tooltip: state.reason || "Set up mention notifications on this device."}
  }

  return {action: `Mention notifications unavailable for ${scopeLabel}: ${state.reason || "Unavailable"}`, tooltip: state.reason || "Mention notifications are unavailable on this device."}
}
