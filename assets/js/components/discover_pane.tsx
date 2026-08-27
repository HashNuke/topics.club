import React, {useMemo, useState} from "react"
import DiscoveryChannelCard from "./discovery_channel_card.tsx"
import type {ServerChannel, ServerConnection} from "../types.ts"

type DiscoverTab = "all" | "server"

export interface DiscoverPaneProps {
  activeServer?: ServerConnection
  serverChannels: ServerChannel[]
  error?: string | null
  initialTab?: DiscoverTab
  joiningServerChannelId?: string | number | null
  loading?: boolean
  onJoinServerChannel: (serverChannel: ServerChannel) => void
  onJoinThisServer: (channel: string) => void
  pageSize?: number
}

function normalizeChannelName(value: string): string {
  const channel = value.trim()
  if (!channel) return ""
  return /^[#&+!]/.test(channel) ? channel : `#${channel}`
}

function formatUsers(count: number): string {
  return new Intl.NumberFormat().format(count)
}

function refreshedLabel(serverChannels: ServerChannel[]): string | null {
  const value = serverChannels.find((serverChannel) => serverChannel.refreshed_at)?.refreshed_at
  if (!value) return null

  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return null
  return `Updated ${date.toLocaleDateString(undefined, {month: "short", day: "numeric"})}`
}

export default function DiscoverPane({activeServer, serverChannels, error, initialTab = "all", joiningServerChannelId, loading = false, onJoinServerChannel, onJoinThisServer, pageSize = 12}: DiscoverPaneProps) {
  const [tab, setTab] = useState<DiscoverTab>(initialTab === "server" && !activeServer ? "all" : initialTab)
  const [page, setPage] = useState(1)
  const [manualChannel, setManualChannel] = useState("")
  const serverLabel = activeServer?.name || activeServer?.host

  const sortedChannels = useMemo(
    () => [...serverChannels].sort((left, right) => right.user_count - left.user_count || left.name.localeCompare(right.name)),
    [serverChannels]
  )
  const visibleChannels = tab === "server" && activeServer
    ? sortedChannels.filter((channel) => channel.server_host.toLowerCase() === activeServer.host.toLowerCase())
    : sortedChannels
  const pageCount = Math.max(1, Math.ceil(visibleChannels.length / pageSize))
  const currentPage = Math.min(page, pageCount)
  const paginatedChannels = visibleChannels.slice((currentPage - 1) * pageSize, currentPage * pageSize)
  const updated = refreshedLabel(visibleChannels)

  function selectTab(nextTab: DiscoverTab): void {
    setTab(nextTab)
    setPage(1)
  }

  function submitManualChannel(event: React.FormEvent<HTMLFormElement>): void {
    event.preventDefault()
    const channel = normalizeChannelName(manualChannel)
    if (!activeServer || !channel) return
    onJoinThisServer(channel)
  }

  return (
    <section className="relative min-h-0 flex-1 overflow-y-auto bg-[var(--app-canvas)] px-4 py-6 sm:px-7 sm:py-8">
      <div className="pointer-events-none absolute inset-x-0 top-0 h-72 bg-[radial-gradient(circle_at_28%_0%,rgba(181,167,255,0.1),transparent_55%)]" />
      <div className="relative mx-auto max-w-6xl">
        <header className="max-w-2xl">
          <div className="mb-3 inline-flex items-center gap-2 rounded-full border border-cyan-300/15 bg-cyan-300/5 px-3 py-1 text-[11px] font-semibold uppercase tracking-[0.18em] text-cyan-200">
            <span className="hero-globe-alt size-3.5" aria-hidden="true" /> IRC directory
          </div>
          <h1 className="text-3xl font-semibold tracking-[-0.035em] text-white sm:text-4xl">Find your next conversation.</h1>
          <p className="mt-3 text-sm leading-6 text-slate-400 sm:text-base">Browse public channels ordered by recent directory activity, or jump straight into a channel on your current server.</p>
        </header>

        <div className="mt-7 flex border-b border-white/8" role="tablist" aria-label="Discover channels">
          <button role="tab" aria-selected={tab === "all"} type="button" onClick={() => selectTab("all")} className={["relative px-1 pb-3 pr-5 text-sm font-semibold transition", tab === "all" ? "text-white after:absolute after:inset-x-0 after:-bottom-px after:h-0.5 after:rounded-full after:bg-cyan-300" : "text-white/45 hover:text-white/75"].join(" ")}>All IRC servers</button>
          {activeServer && <button role="tab" aria-selected={tab === "server"} type="button" onClick={() => selectTab("server")} className={["relative px-1 pb-3 pl-5 text-sm font-semibold transition", tab === "server" ? "text-white after:absolute after:inset-x-0 after:-bottom-px after:h-0.5 after:rounded-full after:bg-cyan-300" : "text-white/45 hover:text-white/75"].join(" ")}>{`This server · ${serverLabel}`}</button>}
        </div>

        {tab === "server" && (
          <form role="form" aria-label={`Join a channel on ${serverLabel || "this server"}`} onSubmit={submitManualChannel} className="mt-6 rounded-2xl border border-white/8 bg-white/[0.025] p-4 sm:flex sm:items-end sm:gap-3 sm:p-5">
            <label className="block min-w-0 flex-1 text-xs font-semibold text-slate-300">
              Channel name
              <input value={manualChannel} disabled={!activeServer} onChange={(event) => setManualChannel(event.target.value)} placeholder="#channel" className="mt-2 w-full rounded-xl border border-white/10 bg-[var(--app-input)] px-3.5 py-3 text-sm text-white outline-none transition placeholder:text-slate-600 focus:border-cyan-300/60 focus:ring-2 focus:ring-cyan-300/10 disabled:cursor-not-allowed disabled:opacity-50" />
            </label>
            <button type="submit" disabled={!activeServer || !manualChannel.trim()} className="mt-3 w-full rounded-xl bg-cyan-300 px-5 py-3 text-sm font-bold text-cyan-950 transition hover:bg-cyan-200 disabled:cursor-not-allowed disabled:opacity-40 sm:mt-0 sm:w-auto">Join channel</button>
          </form>
        )}

        <div className="mt-7 flex items-end justify-between gap-4">
          <div>
            <h2 className="text-base font-semibold text-white">{tab === "all" ? "Popular across IRC" : serverLabel ? `Popular on ${serverLabel}` : "Channels on this server"}</h2>
            <p className="mt-1 text-xs text-slate-500">{visibleChannels.length ? `${formatUsers(visibleChannels.length)} public channels` : "Public channel listings will appear here."}</p>
          </div>
          {updated && <span className="shrink-0 text-xs text-slate-600">{updated}</span>}
        </div>

        {error && <div role="alert" className="mt-5 rounded-xl border border-rose-300/20 bg-rose-300/8 px-4 py-3 text-sm text-rose-200">{error}</div>}
        {loading ? (
          <div aria-label="Loading channel directory" className="mt-5 grid gap-3 sm:grid-cols-2 xl:grid-cols-3">{Array.from({length: 6}, (_, index) => <div key={index} className="h-44 animate-pulse rounded-2xl border border-white/6 bg-white/[0.035]" />)}</div>
        ) : paginatedChannels.length ? (
          <div className="mt-5 grid gap-3 sm:grid-cols-2 xl:grid-cols-3">
            {paginatedChannels.map((serverChannel) => <DiscoveryChannelCard key={serverChannel.id} serverChannel={serverChannel} joining={String(joiningServerChannelId) === String(serverChannel.id)} onJoin={() => onJoinServerChannel(serverChannel)} />)}
          </div>
        ) : (
          <div className="mt-5 rounded-2xl border border-dashed border-white/10 px-6 py-14 text-center">
            <p className="text-sm font-semibold text-slate-300">No cached channels yet</p>
            <p className="mt-1 text-xs text-slate-600">{activeServer ? "Use the current-server tab to enter a channel name directly." : "Connect to an IRC server or wait for the directory refresh."}</p>
          </div>
        )}

        {!loading && visibleChannels.length > pageSize && (
          <nav aria-label="Discover pagination" className="mt-7 flex items-center justify-between border-t border-white/8 pt-5">
            <button type="button" aria-label="Previous page" disabled={currentPage === 1} onClick={() => setPage((value) => Math.max(1, value - 1))} className="rounded-lg border border-white/10 px-3 py-2 text-xs font-semibold text-slate-300 transition hover:border-white/20 hover:text-white disabled:opacity-30">Previous</button>
            <span className="text-xs font-medium tabular-nums text-slate-500">Page {currentPage} of {pageCount}</span>
            <button type="button" aria-label="Next page" disabled={currentPage === pageCount} onClick={() => setPage((value) => Math.min(pageCount, value + 1))} className="rounded-lg border border-white/10 px-3 py-2 text-xs font-semibold text-slate-300 transition hover:border-white/20 hover:text-white disabled:opacity-30">Next</button>
          </nav>
        )}
      </div>
    </section>
  )
}
