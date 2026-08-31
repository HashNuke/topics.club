import React from "react"
import {InlineLoader} from "generative-loaders"
import ChannelDirectoryPagination from "./channel_directory_pagination.tsx"
import type {ChannelDirectoryEntry} from "../types.ts"
import type {ChannelDirectoryState} from "../hooks/use_channel_directory.ts"

interface ChannelDirectoryResultsProps {
  channels: ChannelDirectoryEntry[]
  directory: ChannelDirectoryState
  onJoinChannel: (channel: string) => void
  onPageChange: (page: number) => void
  serverName?: string
}

export default function ChannelDirectoryResults({channels, directory, onJoinChannel, onPageChange, serverName}: ChannelDirectoryResultsProps) {
  if (directory?.status === "loading") {
    return (
      <div
        className="overflow-hidden rounded-lg border border-cyan-300/15 bg-[var(--app-panel)]"
        aria-label={`Loading channels from ${serverName || "the server"}`}
        aria-live="polite"
        role="status"
      >
        <div className="flex min-h-48 items-center justify-center px-5 py-10 text-center">
          <div className="max-w-md">
            <span className="mx-auto inline-flex size-11 items-center justify-center rounded-full border border-cyan-300/20 bg-cyan-300/8 text-cyan-200 shadow-[0_0_28px_rgba(103,232,249,0.08)]">
              <InlineLoader variant="signal" size="1.35rem" color="currentColor" />
            </span>
            <p className="mt-4 text-sm font-semibold text-slate-100">
              Asking {serverName || "the server"} for its channel list
            </p>
            <p className="mt-1.5 text-sm leading-6 text-slate-400">
              Large IRC networks can take a few seconds to send the complete list. You can keep browsing as soon as it arrives.
            </p>
          </div>
        </div>
      </div>
    )
  }

  if (directory?.status !== "ready") return null

  if (channels.length === 0) {
    return (
      <div className="border-y border-slate-800 py-12 text-center">
        <span className="hero-magnifying-glass mx-auto block size-6 text-slate-600" aria-hidden="true" />
        <p className="mt-3 text-sm font-medium text-slate-300">No matching channels found.</p>
        <p className="mt-1 text-sm text-slate-500">Try a broader search or join by name.</p>
      </div>
    )
  }

  return (
    <div className="overflow-hidden rounded-lg border border-slate-800 bg-[var(--app-panel)]">
      <div className="flex items-center justify-between border-b border-slate-800 px-4 py-3 text-xs font-semibold uppercase tracking-[0.14em] text-slate-500" aria-live="polite" role="status">
        <span>{directory.totalChannels} {directory.totalChannels === 1 ? "channel" : "channels"}</span>
        <span>Join a channel</span>
      </div>
      <div className="border-b border-slate-800">
        <ChannelDirectoryPagination
          ariaLabel="Channel directory pagination above results"
          onPageChange={onPageChange}
          page={directory.page}
          pageSize={directory.pageSize}
          totalChannels={directory.totalChannels}
          totalPages={directory.totalPages}
        />
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
      <div className="border-t border-slate-800">
        <ChannelDirectoryPagination
          ariaLabel="Channel directory pagination below results"
          onPageChange={onPageChange}
          page={directory.page}
          pageSize={directory.pageSize}
          totalChannels={directory.totalChannels}
          totalPages={directory.totalPages}
        />
      </div>
    </div>
  )
}
