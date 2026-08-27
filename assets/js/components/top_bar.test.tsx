import {render, screen} from "@testing-library/react"
import {describe, expect, test, vi} from "vitest"
import TopBar from "./top_bar.tsx"
import type {NotificationDeviceState} from "../browser_notifications.ts"
import type {Channel} from "../types.ts"

function renderTopBar(
  notificationDeviceState: NotificationDeviceState,
  activeChannel: Channel = {
    id: "channel:1",
    buffer_type: "channel",
    channel_membership_id: 1,
    channel: "#elixir",
    mention_notifications_enabled: true,
    notification_preference_revision: 0,
  }
) {
  const onToggleChannelNotifications = vi.fn()
  render(
    <TopBar
      activeChannel={activeChannel}
      activeServer={{id: "server:1", server_connection_id: 1, name: "Libera Chat", host: "irc.libera.chat", mention_notifications_enabled: true, notification_preference_revision: 0, channels: []}}
      connectionHealth="connected"
      notificationDeviceState={notificationDeviceState}
      notificationSavingIds={new Set()}
      showsUserSidebar={false}
      view="chat"
      onOpenMobileMenu={() => {}}
      onOpenMobileUsers={() => {}}
      onToggleChannelNotifications={onToggleChannelNotifications}
      onRetryRealtime={() => {}}
    />
  )
  return onToggleChannelNotifications
}

describe("TopBar notification bell", () => {
  test("allows notification permission requests on a capable device", () => {
    renderTopBar({capability: "default", configured: true, loading: false, subscribed: false})

    expect(screen.getByRole("button", {name: "Set up mention notifications for #elixir"})).toBeEnabled()
  })

  test.each([
    ["insecure", "Notifications require HTTPS or localhost."],
    ["unsupported", "This browser or installation does not support Web Push."],
    ["denied", "Notifications are blocked in browser or operating-system settings."],
  ] as const)("disables the bell when notifications are %s", (state, label) => {
    renderTopBar({capability: state, configured: true, loading: false, subscribed: false})

    expect(screen.getByRole("button", {name: `Mention notifications unavailable for #elixir: ${label}`})).toBeDisabled()
  })
})

describe("TopBar channel heading", () => {
  test("shows fallback server context only once on desktop while retaining it on mobile", () => {
    renderTopBar(
      {capability: "granted", configured: true, loading: false, subscribed: true},
      {
        id: "channel:1",
        buffer_type: "channel",
        channel_membership_id: 1,
        channel: "#linux",
        topic: "on irc.libera.chat",
        connection: {host: "irc.libera.chat"},
        mention_notifications_enabled: true,
        notification_preference_revision: 0,
      }
    )

    const serverLabels = screen.getAllByText("on irc.libera.chat")
    const desktopContext = serverLabels.find((element) => element.tagName === "SPAN")
    const mobileSubtitle = serverLabels.find((element) => element.tagName === "P")

    expect(desktopContext).toHaveClass("sm:inline")
    expect(mobileSubtitle).toHaveClass("sm:hidden")
  })
})
