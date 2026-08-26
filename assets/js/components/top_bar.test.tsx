import {render, screen} from "@testing-library/react"
import {describe, expect, test, vi} from "vitest"
import TopBar from "./top_bar.tsx"
import type {BrowserNotificationState} from "../browser_notifications.ts"

function renderTopBar(notificationState: BrowserNotificationState) {
  const onRequestNotifications = vi.fn()
  render(
    <TopBar
      activeChannel={{id: "channel:1", channel: "#elixir"}}
      connectionHealth="connected"
      notificationState={notificationState}
      showsUserSidebar={false}
      view="chat"
      onOpenMobileMenu={() => {}}
      onOpenMobileUsers={() => {}}
      onRequestNotifications={onRequestNotifications}
      onRetryRealtime={() => {}}
    />
  )
  return onRequestNotifications
}

describe("TopBar notification bell", () => {
  test("allows notification permission requests on a capable device", () => {
    renderTopBar("default")

    expect(screen.getByRole("button", {name: "Enable browser notifications"})).toBeEnabled()
  })

  test.each([
    ["insecure", "Browser notifications require HTTPS"],
    ["unsupported", "Browser notifications unavailable"],
    ["denied", "Browser notifications blocked"],
  ] as const)("disables the bell when notifications are %s", (state, label) => {
    renderTopBar(state)

    expect(screen.getByRole("button", {name: label})).toBeDisabled()
  })
})
