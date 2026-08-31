import React from "react"

interface ChannelDirectoryHeaderProps {
  serverName?: string
}

export default function ChannelDirectoryHeader({serverName}: ChannelDirectoryHeaderProps) {
  return (
    <div className="border-b border-slate-800 pb-6">
      <div className="max-w-2xl">
        <h2 className="text-2xl font-semibold tracking-tight text-white">Find your next conversation</h2>
        <p className="mt-2 text-sm leading-6 text-slate-400">
          This is the channel list visible to your connection on {serverName || "the server"}. It is cached for up to 24 hours and refreshed when your IRC identity or channel visibility changes. Private channels and channels hidden by the server will not appear.
        </p>
      </div>
    </div>
  )
}
