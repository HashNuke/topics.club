import AppShell from "./app_shell.jsx"

const channel = {id: "channel:1", channel: "#elixir", topic: "Phoenix and OTP help", mention_count: 1, connection: {host: "irc.example.net", status: "connected"}}
const server = {id: "server:1", server_connection_id: 1, name: "Example IRC", host: "irc.example.net", port: 6697, status: "connected", channels: [channel]}
const topics = [{id: "elixir", channel: "#elixir", server_host: "irc.example.net", description: "Phoenix and OTP help.", members: 426}]
const messages = [{id: "message:1", nick: "mira", body: "Welcome to the full app shell preview.", kind: "message", occurredAt: "2026-08-25T15:00:00Z"}]
const users = [{nick: "mira", role: "op", status: "online"}, {nick: "akash", role: "user", status: "online"}]
const noop = () => {}

export default {title: "App/AppShell", component: AppShell, parameters: {layout: "fullscreen"}, args: {activeChannel: channel, activeServer: server, channelDirectory: {channels: topics.map((topic) => ({channel: topic.channel, topic: topic.description, users: topic.members})), status: "ready"}, commandCatalog: [], composerError: null, connectionHealth: "connected", connections: [server], currentUser: {email: "mira@example.com"}, draft: "", messages, notificationState: "default", serverMessages: messages, topics, users, view: "chat", onDiscover: noop, onDisconnectServer: noop, onJoinDirectoryChannel: noop, onJoinManualServer: noop, onLeaveChannel: noop, onLeaveServer: noop, onLoadOlderMessages: noop, onMarkChannelRead: noop, onOpenChannelDirectory: noop, onReadingStateChange: noop, onReconnectServer: noop, onRequestNotifications: noop, onRetryMessage: noop, onRetryRealtime: noop, onSelectChannel: noop, onSelectServer: noop, onSendMessage: (event) => event.preventDefault(), onShowChat: noop, onUpdateDraft: noop, onUpdateServer: noop, onSelectTopic: noop}}
export const Chat = {}
export const Discover = {args: {view: "discover"}}
export const Directory = {args: {view: "directory"}}
export const ServerBuffer = {args: {view: "server"}}
export const MobileChannels = {args: {initialMobileMenuOpen: true}, parameters: {viewport: {defaultViewport: "mobile1"}}}
export const MobilePeople = {args: {initialMobileUsersOpen: true}, parameters: {viewport: {defaultViewport: "mobile1"}}}
