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
          This list comes from {serverName || "the server"} and is cached for up to one hour. Private channels and channels hidden by the server will not appear.
        </p>
      </div>
    </div>
  )
}
