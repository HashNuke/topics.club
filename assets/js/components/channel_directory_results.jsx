export default function ChannelDirectoryResults({channels, directory, onJoinChannel, serverName}) {
  if (directory?.status === "loading") {
    return (
      <div className="overflow-hidden rounded-lg border border-slate-800 bg-[#10151e]" aria-label={`Loading channels from ${serverName || "the server"}`} aria-live="polite" role="status">
        <span className="sr-only">Asking {serverName || "the server"} for its public channels.</span>
        {[0, 1, 2].map((row) => (
          <div key={row} className="grid animate-pulse gap-3 border-b border-slate-800/90 px-4 py-5 last:border-b-0 sm:grid-cols-[minmax(0,1fr)_5rem]">
            <div>
              <div className="h-3 w-28 rounded bg-slate-700/80" />
              <div className="mt-3 h-2.5 w-3/5 rounded bg-slate-800" />
            </div>
            <div className="h-9 rounded-md bg-slate-800" />
          </div>
        ))}
      </div>
    )
  }

  if (directory?.status !== "ready") return null

  if (channels.length === 0) {
    return (
      <div className="border-y border-slate-800 py-12 text-center">
        <span className="hero-magnifying-glass mx-auto block size-6 text-slate-600" aria-hidden="true" />
        <p className="mt-3 text-sm font-medium text-slate-300">No matching channels found.</p>
        <p className="mt-1 text-sm text-slate-500">Try a broader search, refresh the list, or join by name.</p>
      </div>
    )
  }

  return (
    <div className="overflow-hidden rounded-lg border border-slate-800 bg-[#10151e]">
      <div className="flex items-center justify-between border-b border-slate-800 px-4 py-3 text-xs font-semibold uppercase tracking-[0.14em] text-slate-500" aria-live="polite" role="status">
        <span>{channels.length} {channels.length === 1 ? "channel" : "channels"}</span>
        <span>Join a channel</span>
      </div>
      <div className="divide-y divide-slate-800/90">
        {channels.map((channel) => {
          const joining = directory.joiningChannel === channel.channel
          return (
            <article key={channel.channel} className="group grid gap-3 px-4 py-4 transition hover:bg-slate-900/70 sm:grid-cols-[minmax(0,1fr)_auto] sm:items-center">
              <div className="min-w-0">
                <div className="flex flex-wrap items-center gap-x-3 gap-y-1">
                  <h3 className="font-mono text-sm font-semibold text-cyan-200">{channel.channel}</h3>
                  <span className="text-xs tabular-nums text-slate-500">{channel.users} {channel.users === 1 ? "person" : "people"}</span>
                </div>
                <p className="mt-1.5 truncate text-sm text-slate-400" title={channel.topic || "No topic set"}>{channel.topic || "No topic set"}</p>
              </div>
              <button
                className={[
                  "h-9 rounded-md px-4 text-sm font-semibold transition disabled:cursor-wait",
                  joining ? "bg-slate-700 text-white/70" : "bg-cyan-300 text-cyan-950 hover:bg-white",
                ].join(" ")}
                disabled={joining}
                onClick={() => onJoinChannel(channel.channel)}
                type="button"
              >
                {joining ? "Joining…" : "Join"}
              </button>
            </article>
          )
        })}
      </div>
    </div>
  )
}
