import React from "react"

interface ChannelDirectoryControlsProps {
  manualChannel: string
  onJoinManualChannel: React.FormEventHandler<HTMLFormElement>
  onUpdateManualChannel: (value: string) => void
  onUpdateQuery: (value: string) => void
  query: string
}

export default function ChannelDirectoryControls({manualChannel, onJoinManualChannel, onUpdateManualChannel, onUpdateQuery, query}: ChannelDirectoryControlsProps) {
  return (
    <div className="grid gap-3 py-5 md:grid-cols-[minmax(0,1fr)_minmax(18rem,0.55fr)]">
      <label className="block" htmlFor="channel-directory-search">
        <span className="mb-1.5 block text-xs font-semibold uppercase tracking-[0.14em] text-slate-500">Search this server</span>
        <span className="flex h-11 items-center gap-2 rounded-md border border-slate-700 bg-[var(--app-panel)] px-3 transition focus-within:border-cyan-300/70 focus-within:ring-2 focus-within:ring-cyan-300/10">
          <span className="hero-magnifying-glass size-4 text-slate-500" aria-hidden="true" />
          <input
            id="channel-directory-search"
            className="min-w-0 flex-1 border-0 bg-transparent text-sm text-white outline-none placeholder:text-slate-600"
            onChange={(event) => onUpdateQuery(event.target.value)}
            placeholder="Try elixir, games, or music"
            type="search"
            value={query}
          />
        </span>
      </label>

      <form id="channel-directory-join-form" onSubmit={onJoinManualChannel}>
        <label className="mb-1.5 block text-xs font-semibold uppercase tracking-[0.14em] text-slate-500" htmlFor="channel-directory-manual">
          Know the channel name?
        </label>
        <div className="flex h-11 overflow-hidden rounded-md border border-slate-700 bg-[var(--app-panel)] transition focus-within:border-cyan-300/70 focus-within:ring-2 focus-within:ring-cyan-300/10">
          <input
            id="channel-directory-manual"
            className="min-w-0 flex-1 border-0 bg-transparent px-3 text-sm text-white outline-none placeholder:text-slate-600"
            onChange={(event) => onUpdateManualChannel(event.target.value)}
            placeholder="#channel"
            value={manualChannel}
          />
          <button className="border-l border-slate-700 px-4 text-sm font-semibold text-cyan-200 transition hover:bg-cyan-300 hover:text-cyan-950" type="submit">
            Join
          </button>
        </div>
      </form>
    </div>
  )
}
