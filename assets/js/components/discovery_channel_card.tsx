import React from "react"
import type {ServerChannel} from "../types.ts"

export interface DiscoveryChannelCardProps {
  joining?: boolean
  onJoin?: () => void
  serverChannel: ServerChannel
}

export default function DiscoveryChannelCard({joining = false, onJoin, serverChannel}: DiscoveryChannelCardProps) {
  return (
    <article
      data-testid="discover-channel"
      className={[
        "group relative flex min-h-40 flex-col overflow-hidden rounded-2xl border border-white/7 bg-[var(--app-panel)] p-4",
        "shadow-[0_18px_50px_rgba(0,0,0,0.16)] transition duration-200",
        onJoin ? "hover:-translate-y-0.5 hover:border-cyan-300/35 hover:bg-[var(--app-panel-hover)]" : "hover:border-white/12",
      ].join(" ")}
    >
      <div className="pointer-events-none absolute inset-x-6 top-0 h-px bg-gradient-to-r from-transparent via-cyan-300/35 to-transparent opacity-0 transition group-hover:opacity-100" />
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0">
          <h3 className="truncate text-lg font-semibold tracking-[-0.025em] text-white">{serverChannel.name}</h3>
          <p className="mt-1 truncate text-xs font-medium text-slate-500">{serverChannel.network_name}</p>
        </div>
        <div className="flex shrink-0 items-center gap-1.5 rounded-full border border-white/8 bg-white/4 px-2.5 py-1 text-xs font-semibold tabular-nums text-slate-300">
          <span className="hero-users size-3.5 text-slate-500" aria-hidden="true" />
          {approximateUserCount(serverChannel.user_count)}
          <span className="sr-only"> users in the latest directory snapshot</span>
        </div>
      </div>
      <p className="mt-3 line-clamp-2 min-h-10 text-sm leading-5 text-slate-400">{serverChannel.topic || "A public IRC channel open for conversation."}</p>
      <div className="mt-auto flex items-end justify-between gap-3 pt-4">
        <span className="truncate text-[11px] text-slate-600">{serverChannel.server_host}</span>
        {onJoin && (
          <button
            type="button"
            disabled={joining}
            aria-label={`Join ${serverChannel.name} on ${serverChannel.network_name}`}
            onClick={onJoin}
            className="rounded-lg bg-cyan-300 px-3 py-2 text-xs font-bold text-cyan-950 transition duration-200 hover:-translate-y-px hover:bg-cyan-200 hover:shadow-lg hover:shadow-cyan-950/20 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-cyan-300 disabled:cursor-wait disabled:opacity-60"
          >
            {joining ? "Joining…" : "Join channel"}
          </button>
        )}
      </div>
    </article>
  )
}

export function approximateUserCount(count: number): string {
  const wholeCount = Math.max(0, Math.floor(count))
  if (wholeCount === 0) return "0"

  const magnitude = 10 ** Math.floor(Math.log10(wholeCount))
  const flooredCount = Math.floor(wholeCount / magnitude) * magnitude

  if (flooredCount >= 1_000_000) return `${Math.floor(flooredCount / 1_000_000)}m+`
  if (flooredCount >= 1_000) return `${Math.floor(flooredCount / 1_000)}k+`
  return `${flooredCount}+`
}
