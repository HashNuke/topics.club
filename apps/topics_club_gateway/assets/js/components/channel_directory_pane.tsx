import React, {useEffect, useState} from "react"
import ChannelDirectoryControls from "./channel_directory_controls.tsx"
import ChannelDirectoryFeedback from "./channel_directory_feedback.tsx"
import ChannelDirectoryHeader from "./channel_directory_header.tsx"
import ChannelDirectoryResults from "./channel_directory_results.tsx"
import type {ChannelDirectoryState} from "../hooks/use_channel_directory.ts"
import type {ServerConnection} from "../types.ts"

interface ChannelDirectoryPaneProps {
  directory: ChannelDirectoryState
  onJoinChannel: (channel: string) => void
  onPageChange: (page: number) => void
  onSearch: (query: string) => void
  server?: ServerConnection
}

export default function ChannelDirectoryPane({directory, onJoinChannel, onPageChange, onSearch, server}: ChannelDirectoryPaneProps) {
  const [query, setQuery] = useState("")
  const [manualChannel, setManualChannel] = useState("")

  useEffect(() => {
    setQuery(directory.query)
  }, [directory.query, directory.serverId])

  function search(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault()
    onSearch(query.trim())
  }

  function joinManualChannel(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault()
    const channel = manualChannel.trim()
    if (!channel) return
    onJoinChannel(channel)
  }

  return (
    <section id="channel-directory" className="min-h-0 flex-1 overflow-y-auto bg-[var(--app-canvas)] px-4 py-5 sm:px-6 sm:py-7">
      <div className="mx-auto max-w-5xl">
        <ChannelDirectoryHeader serverName={server?.name} />
        <ChannelDirectoryControls
          manualChannel={manualChannel}
          onJoinManualChannel={joinManualChannel}
          onSearch={search}
          onUpdateManualChannel={setManualChannel}
          onUpdateQuery={setQuery}
          query={query}
        />
        <ChannelDirectoryFeedback
          error={directory?.error}
          joinError={directory?.joinError}
          onRetry={() => onSearch(query.trim())}
        />
        <ChannelDirectoryResults
          channels={directory.channels}
          directory={directory}
          onJoinChannel={onJoinChannel}
          onPageChange={onPageChange}
          serverName={server?.name}
        />
      </div>
    </section>
  )
}
