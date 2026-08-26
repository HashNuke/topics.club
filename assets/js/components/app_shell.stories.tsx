import AppShell from "./app_shell.tsx"

const channel = {id: "channel:1", channel: "#elixir", topic: "Phoenix and OTP help", mention_count: 1, connection: {host: "irc.example.net", status: "connected"}}
const server = {id: "server:1", server_connection_id: 1, name: "Example IRC", host: "irc.example.net", port: 6697, status: "connected", channels: [channel]}
const topics = [{id: "elixir", channel: "#elixir", server_host: "irc.example.net", description: "Phoenix and OTP help.", members: 426}]
const messages = [{id: "message:1", nick: "mira", body: "Welcome to the full app shell preview.", kind: "message", occurredAt: "2026-08-25T15:00:00Z"}]
const users = [{nick: "mira", role: "op", status: "online"}, {nick: "akash", role: "user", status: "online"}]
const noop = () => {}
const directMessage = {id: "direct:8", buffer_type: "direct_message", direct_message_thread_id: 8, channel: "akash", topic: "on irc.example.net", unread_count: 2, account: "akash-account", blocked: false, connection: {name: "Example IRC", host: "irc.example.net", status: "connected"}}
const directServer = {...server, channels: [directMessage, channel]}

export default {title: "App/AppShell", component: AppShell, parameters: {layout: "fullscreen"}, args: {activeChannel: channel, activeServer: server, channelDirectory: {channels: topics.map((topic) => ({channel: topic.channel, topic: topic.description, users: topic.members})), status: "ready"}, commandCatalog: [], composerError: null, connectionHealth: "connected", connections: [server], currentUser: {email: "mira@example.com"}, discoverServerChannels: topics.map((topic, index) => ({id: index + 1, name: topic.channel, topic: topic.description, user_count: topic.members, network_id: 1, network_name: "Example IRC", server_host: topic.server_host, server_port: 6697, use_tls: true})), discoverLoading: false, draft: "", messages, messagesLoading: false, notificationDeviceState: {capability: "granted", configured: true, loading: false, subscribed: true}, notificationSavingIds: new Set(), serverMessages: messages, topics, users, view: "chat", onCloseDirectMessage: noop, onDiscover: noop, onDisconnectServer: noop, onJoinDirectoryChannel: noop, onJoinDiscoverServerChannel: noop, onJoinThisServerChannel: noop, onJoinManualServer: noop, onLeaveChannel: noop, onLeaveServer: noop, onLoadOlderMessages: noop, onMarkChannelRead: noop, onOpenChannelDirectory: noop, onReadingStateChange: noop, onReconnectServer: noop, onRetryMessage: noop, onRetryRealtime: noop, onSelectChannel: noop, onSelectServer: noop, onSendMessage: (event: React.FormEvent<HTMLFormElement>) => event.preventDefault(), onSetDirectMessageBlocked: noop, onShowChat: noop, onToggleChannelNotifications: noop, onToggleServerNotifications: noop, onUpdateDraft: noop, onUpdateServer: noop, onSelectTopic: noop}}
export const Chat = {}
export const DirectMessage = {args: {activeChannel: directMessage, activeServer: directServer, connections: [directServer], messages: [{id: "message:dm", nick: "akash", body: "A private hello.", kind: "message"}], users: []}}
export const BlockedDirectMessage = {args: {activeChannel: {...directMessage, blocked: true}, activeServer: directServer, connections: [directServer], users: []}}
export const LoadingMessages = {args: {messages: [], messagesLoading: true}}
export const EmptyMessages = {args: {messages: [], messagesLoading: false}}
export const Discover = {args: {view: "discover"}}
export const Directory = {args: {view: "directory"}}
export const ServerBuffer = {args: {view: "server"}}
export const MobileChannels = {args: {initialMobileMenuOpen: true}, parameters: {viewport: {defaultViewport: "mobile1"}}}
export const MobilePeople = {args: {initialMobileUsersOpen: true}, parameters: {viewport: {defaultViewport: "mobile1"}}}
export const MobileDirectMessage = {args: {...DirectMessage.args, initialMobileUsersOpen: true}, parameters: {viewport: {defaultViewport: "mobile1"}}}
