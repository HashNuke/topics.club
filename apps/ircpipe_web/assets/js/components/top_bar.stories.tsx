import TopBar, {ConnectionHealthIndicator} from "./top_bar.tsx"

export default {title: "Navigation/TopBar", component: TopBar, decorators: [(Story: React.ComponentType) => <div className="w-[64rem] max-w-full"><Story /></div>], args: {activeChannel: {id: "channel:1", channel: "#elixir", topic: "Elixir help", connection: {host: "irc.example.net"}}, activeServer: {name: "Example", host: "irc.example.net"}, connectionHealth: "connected", notificationDeviceState: {capability: "granted", configured: true, loading: false, subscribed: true}, notificationSavingIds: new Set(), showsUserSidebar: true, view: "chat", onOpenMobileMenu: () => {}, onOpenMobileUsers: () => {}, onToggleChannelNotifications: () => {}, onRetryRealtime: () => {}}}
export const Channel = {}
export const ChannelWithoutTopic = {args: {activeChannel: {id: "channel:1", channel: "#linux", topic: "on irc.example.net", connection: {host: "irc.example.net"}}}}
export const DirectMessage = {args: {activeChannel: {id: "direct:8", buffer_type: "direct_message", channel: "akash", topic: "on irc.example.net", connection: {name: "Example", host: "irc.example.net"}}}}
export const BlockedDirectMessage = {args: {activeChannel: {id: "direct:8", buffer_type: "direct_message", channel: "akash", blocked: true, connection: {name: "Example", host: "irc.example.net"}}}}
export const Discover = {args: {view: "discover"}}
export const Directory = {args: {view: "directory"}}
export const Server = {args: {view: "server"}}
export const Degraded = {args: {connectionHealth: "degraded"}}
export const NotificationsAvailable = {args: {notificationDeviceState: {capability: "default", configured: true, loading: false, subscribed: false}}}
export const NotificationsUnavailableOnHttp = {args: {notificationDeviceState: {capability: "insecure", configured: true, loading: false, subscribed: false}}}
export const NotificationsBlocked = {args: {notificationDeviceState: {capability: "denied", configured: true, loading: false, subscribed: false}}}
export const HealthIndicator = {render: () => <ConnectionHealthIndicator status="reconnecting" onRetry={() => {}} />}
