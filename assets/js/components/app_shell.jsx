import React, {useState} from "react"
import ChannelDirectoryPane from "./channel_directory_pane.jsx"
import ChatPane from "./chat_pane.jsx"
import DiscoverPane from "./discover_pane.jsx"
import LeftSidebar from "./left_sidebar.jsx"
import MobileDrawer, {MobileDrawerHeader} from "./mobile_drawer.jsx"
import RightSidebar from "./right_sidebar.jsx"
import ServerBufferPane from "./server_buffer_pane.jsx"
import TopBar from "./top_bar.jsx"

export default function AppShell(props) {
  const [mobileMenuOpen, setMobileMenuOpen] = useState(Boolean(props.initialMobileMenuOpen))
  const [mobileUsersOpen, setMobileUsersOpen] = useState(Boolean(props.initialMobileUsersOpen))
  const showsUserSidebar = props.view === "chat"

  return <main className="min-h-dvh overflow-hidden bg-[#0a0d12] text-slate-100">
    <div className={["grid h-dvh grid-cols-1", showsUserSidebar ? "lg:grid-cols-[260px_minmax(0,1fr)_220px]" : "lg:grid-cols-[260px_minmax(0,1fr)]"].join(" ")}>
      <LeftSidebar {...props} />
      <section className="flex min-h-0 min-w-0 flex-col">
        <TopBar {...props} showsUserSidebar={showsUserSidebar} onOpenMobileMenu={() => setMobileMenuOpen(true)} onOpenMobileUsers={() => setMobileUsersOpen(true)} />
        {props.view === "discover" ? <DiscoverPane topics={props.topics} onSelectTopic={props.onSelectTopic} />
          : props.view === "directory" ? <ChannelDirectoryPane directory={props.channelDirectory} onJoinChannel={props.onJoinDirectoryChannel} onRefresh={() => props.onOpenChannelDirectory(props.activeServer)} server={props.activeServer} />
            : props.view === "server" ? <ServerBufferPane commandCatalog={props.commandCatalog} composerError={props.composerError} draft={props.draft} messages={props.serverMessages} onLoadOlderMessages={props.onLoadOlderMessages} onReadingStateChange={props.onReadingStateChange} onReconnectServer={props.onReconnectServer} server={props.activeServer} onSendMessage={props.onSendMessage} onUpdateDraft={props.onUpdateDraft} connectionHealth={props.connectionHealth} />
              : <ChatPane {...props} />}
      </section>
      {showsUserSidebar && <RightSidebar activeChannel={props.activeChannel} users={props.users} />}
    </div>
    {mobileMenuOpen && <MobileDrawer side="left" onClose={() => setMobileMenuOpen(false)}><MobileDrawerHeader title="Channels" onClose={() => setMobileMenuOpen(false)} /><LeftSidebar {...props} mobile onDiscover={() => { props.onDiscover(); setMobileMenuOpen(false) }} onOpenChannelDirectory={(server) => { props.onOpenChannelDirectory(server); setMobileMenuOpen(false) }} onSelectChannel={(channel) => { props.onSelectChannel(channel); setMobileMenuOpen(false) }} onSelectServer={(server) => { props.onSelectServer(server); setMobileMenuOpen(false) }} /></MobileDrawer>}
    {showsUserSidebar && mobileUsersOpen && <MobileDrawer side="right" onClose={() => setMobileUsersOpen(false)}><MobileDrawerHeader title="People" onClose={() => setMobileUsersOpen(false)} /><RightSidebar activeChannel={props.activeChannel} users={props.users} mobile /></MobileDrawer>}
  </main>
}
