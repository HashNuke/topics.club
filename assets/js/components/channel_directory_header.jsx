import React from "react"

export default function ChannelDirectoryHeader({loading = false, onRefresh, serverName}) {
  return (
    <div className="flex flex-col gap-5 border-b border-slate-800 pb-6 sm:flex-row sm:items-end sm:justify-between">
      <div className="max-w-2xl">
        <h2 className="text-2xl font-semibold tracking-tight text-white">Find your next conversation</h2>
        <p className="mt-2 text-sm leading-6 text-slate-400">
          This list comes from {serverName || "the server"}. Private channels and channels hidden by the server will not appear.
        </p>
      </div>
      <button
        className="inline-flex h-9 shrink-0 items-center justify-center gap-2 self-start rounded-md border border-slate-700 px-3 text-sm font-medium text-slate-200 transition hover:border-cyan-300/70 hover:text-white disabled:cursor-wait disabled:opacity-60 sm:self-auto"
        disabled={loading}
        onClick={onRefresh}
        type="button"
      >
        <span className={["hero-arrow-path size-4", loading ? "animate-spin" : ""].join(" ")} aria-hidden="true" />
        Refresh list
      </button>
    </div>
  )
}
