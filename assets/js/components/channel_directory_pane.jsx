import {useState} from "react"
import ChannelDirectoryControls from "./channel_directory_controls.jsx"
import ChannelDirectoryFeedback from "./channel_directory_feedback.jsx"
import ChannelDirectoryHeader from "./channel_directory_header.jsx"
import ChannelDirectoryResults from "./channel_directory_results.jsx"

export default function ChannelDirectoryPane({directory, onJoinChannel, onRefresh, server}) {
  const [query, setQuery] = useState("")
  const [manualChannel, setManualChannel] = useState("")
  const normalizedQuery = query.trim().toLowerCase()
  const visibleChannels = (directory?.channels || []).filter((channel) => {
    if (!normalizedQuery) return true
    return `${channel.channel} ${channel.topic || ""}`.toLowerCase().includes(normalizedQuery)
  })

  function joinManualChannel(event) {
    event.preventDefault()
    const channel = manualChannel.trim()
    if (!channel) return
    onJoinChannel(channel)
  }

  return (
    <section id="channel-directory" className="min-h-0 flex-1 overflow-y-auto bg-[#090b10] px-4 py-5 sm:px-6 sm:py-7">
      <div className="mx-auto max-w-5xl">
        <ChannelDirectoryHeader
          loading={directory?.status === "loading"}
          onRefresh={onRefresh}
          serverName={server?.name}
        />
        <ChannelDirectoryControls
          manualChannel={manualChannel}
          onJoinManualChannel={joinManualChannel}
          onUpdateManualChannel={setManualChannel}
          onUpdateQuery={setQuery}
          query={query}
        />
        <ChannelDirectoryFeedback
          error={directory?.error}
          joinError={directory?.joinError}
          onRefresh={onRefresh}
        />
        <ChannelDirectoryResults
          channels={visibleChannels}
          directory={directory}
          onJoinChannel={onJoinChannel}
          serverName={server?.name}
        />
      </div>
    </section>
  )
}
