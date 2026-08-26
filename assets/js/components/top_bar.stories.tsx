import TopBar, {ConnectionHealthIndicator} from "./top_bar.tsx"

export default {title: "Navigation/TopBar", component: TopBar, decorators: [(Story: React.ComponentType) => <div className="w-[64rem] max-w-full"><Story /></div>], args: {activeChannel: {channel: "#elixir", topic: "Elixir help", connection: {host: "irc.example.net"}}, activeServer: {name: "Example", host: "irc.example.net"}, connectionHealth: "connected", notificationState: "default", showsUserSidebar: true, view: "chat", onOpenMobileMenu: () => {}, onOpenMobileUsers: () => {}, onRequestNotifications: () => {}, onRetryRealtime: () => {}}}
export const Channel = {}
export const Discover = {args: {view: "discover"}}
export const Directory = {args: {view: "directory"}}
export const Server = {args: {view: "server"}}
export const Degraded = {args: {connectionHealth: "degraded"}}
export const NotificationsEnabled = {args: {notificationState: "granted"}}
export const HealthIndicator = {render: () => <ConnectionHealthIndicator status="reconnecting" onRetry={() => {}} />}
