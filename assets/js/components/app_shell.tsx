import React, {useState} from "react"
import ChannelDirectoryPane from "./channel_directory_pane.tsx"
import ChatPane from "./chat_pane.tsx"
import DiscoverPane from "./discover_pane.tsx"
import LeftSidebar from "./left_sidebar.tsx"
import MobileDrawer, {MobileDrawerHeader} from "./mobile_drawer.tsx"
import RightSidebar from "./right_sidebar.tsx"
import ServerBufferPane from "./server_buffer_pane.tsx"
import TopBar from "./top_bar.tsx"
import type {NotificationDeviceState} from "../browser_notifications.ts"
import type {ChannelDirectoryState} from "../hooks/use_channel_directory.ts"
import type {EditServerForm, ManualServerForm} from "../hooks/use_server_connections.ts"
import type {
  AppView,
  Channel,
  ChatUser,
  CommandCatalogEntry,
  ConnectionHealth,
  CurrentUser,
  ServerChannel,
  ServerConnection,
  Topic,
  TimelineMessage,
} from "../types.ts"

export interface AppShellProps {
  activeChannel?: Channel
  activeServer?: ServerConnection
  channelDirectory: ChannelDirectoryState
  connections: ServerConnection[]
  currentUser: CurrentUser
  commandCatalog: CommandCatalogEntry[]
  composerError?: string | null
  connectionHealth: ConnectionHealth
  draft: string
  discoverServerChannels: ServerChannel[]
  discoverError?: string | null
  discoverLoading: boolean
  joiningDiscoveryServerChannelId?: string | number | null
  initialMobileMenuOpen?: boolean
  initialMobileUsersOpen?: boolean
  messages: TimelineMessage[]
  messagesLoading: boolean
  notificationDeviceState: NotificationDeviceState
  notificationSavingIds: Set<string>
  serverMessages: TimelineMessage[]
  topics: Topic[]
  users: ChatUser[]
  view: AppView
  onDiscover: () => void
  onCloseDirectMessage: (channel: Channel) => void
  onDisconnectServer: (server: ServerConnection) => void
  onJoinDirectoryChannel: (channel: string) => void
  onJoinDiscoverServerChannel: (serverChannel: ServerChannel) => void
  onJoinThisServerChannel: (channel: string) => void
  onJoinManualServer: (form: ManualServerForm) => void
  onLeaveChannel: (channel: Channel) => void
  onLeaveServer: (server: ServerConnection) => void
  onLoadOlderMessages?: (bufferId?: string) => void
  onMarkChannelRead: (channel: Channel) => void
  onMentionNick?: (nick: string) => void
  onOpenChannelDirectory: (server: ServerConnection) => void
  onReadingStateChange?: (bufferId: string | undefined, readingOlder: boolean) => void
  onReconnectServer: (server: ServerConnection) => void
  onToggleChannelNotifications: (channel: Channel) => void
  onToggleServerNotifications: (server: ServerConnection) => void
  onRetryMessage: (message: TimelineMessage) => void
  onRetryRealtime: () => void
  onSetDirectMessageBlocked: (channel: Channel, blocked: boolean) => void
  onSelectChannel: (channel: Channel) => void
  onSelectServer: (server: ServerConnection) => void
  onSelectTopic: (topic: Topic) => void
  onSendMessage: React.FormEventHandler<HTMLFormElement>
  onShowChat: () => void
  onUpdateDraft: (value: string) => void
  onUpdateServer: (server: ServerConnection, form: EditServerForm) => void
}

export default function AppShell(props: AppShellProps) {
  const [mobileMenuOpen, setMobileMenuOpen] = useState(Boolean(props.initialMobileMenuOpen))
  const [mobileUsersOpen, setMobileUsersOpen] = useState(Boolean(props.initialMobileUsersOpen))
  const showsUserSidebar = props.view === "chat"

  return <main className="min-h-dvh overflow-hidden bg-[var(--app-canvas)] text-slate-100">
    <div className={["grid h-dvh grid-cols-1", showsUserSidebar ? "lg:grid-cols-[232px_minmax(0,1fr)_220px] xl:grid-cols-[240px_minmax(0,1fr)_220px]" : "lg:grid-cols-[232px_minmax(0,1fr)] xl:grid-cols-[240px_minmax(0,1fr)]"].join(" ")}>
      <LeftSidebar {...props} />
      <section className="flex min-h-0 min-w-0 flex-col">
        <TopBar {...props} showsUserSidebar={showsUserSidebar} onOpenMobileMenu={() => setMobileMenuOpen(true)} onOpenMobileUsers={() => setMobileUsersOpen(true)} />
        {props.view === "discover" ? <DiscoverPane activeServer={props.activeServer} serverChannels={props.discoverServerChannels} error={props.discoverError} joiningServerChannelId={props.joiningDiscoveryServerChannelId} loading={props.discoverLoading} onJoinServerChannel={props.onJoinDiscoverServerChannel} onJoinThisServer={props.onJoinThisServerChannel} />
          : props.view === "directory" ? <ChannelDirectoryPane directory={props.channelDirectory} onJoinChannel={props.onJoinDirectoryChannel} onRefresh={() => props.activeServer && props.onOpenChannelDirectory(props.activeServer)} server={props.activeServer} />
            : props.view === "server" ? <ServerBufferPane commandCatalog={props.commandCatalog} composerError={props.composerError} draft={props.draft} messages={props.serverMessages} onLoadOlderMessages={props.onLoadOlderMessages} onReadingStateChange={props.onReadingStateChange} onReconnectServer={props.onReconnectServer} server={props.activeServer} onSendMessage={props.onSendMessage} onUpdateDraft={props.onUpdateDraft} connectionHealth={props.connectionHealth} />
              : <ChatPane {...props} />}
      </section>
      {showsUserSidebar && <RightSidebar activeChannel={props.activeChannel} users={props.users} onSetDirectMessageBlocked={props.onSetDirectMessageBlocked} />}
    </div>
    {mobileMenuOpen && <MobileDrawer side="left" onClose={() => setMobileMenuOpen(false)}><MobileDrawerHeader title="Channels" onClose={() => setMobileMenuOpen(false)} /><LeftSidebar {...props} mobile onDiscover={() => { props.onDiscover(); setMobileMenuOpen(false) }} onOpenChannelDirectory={(server) => { props.onOpenChannelDirectory(server); setMobileMenuOpen(false) }} onSelectChannel={(channel) => { props.onSelectChannel(channel); setMobileMenuOpen(false) }} onSelectServer={(server) => { props.onSelectServer(server); setMobileMenuOpen(false) }} /></MobileDrawer>}
    {showsUserSidebar && mobileUsersOpen && <MobileDrawer side="right" onClose={() => setMobileUsersOpen(false)}><MobileDrawerHeader title={props.activeChannel?.buffer_type === "direct_message" ? "Private message" : "People"} onClose={() => setMobileUsersOpen(false)} /><RightSidebar activeChannel={props.activeChannel} users={props.users} mobile onSetDirectMessageBlocked={props.onSetDirectMessageBlocked} /></MobileDrawer>}
  </main>
}
