import NotificationBell from "./notification_bell.tsx"

export default {
  title: "Notifications/NotificationBell",
  component: NotificationBell,
  decorators: [(Story: React.ComponentType) => <div className="flex min-h-32 min-w-80 items-start justify-end bg-[var(--app-header)] p-8"><Story /></div>],
  args: {id: "story-notification-bell", scopeLabel: "#elixir", onToggle: () => {}},
}

export const Enabled = {args: {state: {kind: "enabled"}}}
export const EnabledWithSyncError = {args: {state: {kind: "enabled", reason: "Notifications are enabled locally but could not be synchronized."}}}
export const Disabled = {args: {state: {kind: "disabled"}}}
export const AvailableToSetUp = {args: {state: {kind: "available"}}}
export const UnavailableOnHttp = {args: {state: {kind: "unavailable", reason: "Notifications require HTTPS or localhost."}}}
export const PermissionBlocked = {args: {state: {kind: "unavailable", reason: "Notifications are blocked in browser or operating-system settings."}}}
export const ServerMuted = {args: {state: {kind: "disabled", reason: "Mentions are muted because Libera Chat notifications are off."}}}
export const Saving = {args: {state: {kind: "enabled"}, loading: true}}
export const CompactServerRowAtViewportEdge = {
  args: {state: {kind: "enabled"}, compact: true, scopeLabel: "Libera Chat"},
  decorators: [(Story: React.ComponentType) => (
    <div className="fixed left-0 top-8 w-64 overflow-hidden bg-[var(--app-sidebar)] p-2">
      <div className="flex justify-end"><Story /></div>
    </div>
  )],
}
