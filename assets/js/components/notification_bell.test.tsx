import {fireEvent, render, screen} from "@testing-library/react"
import {describe, expect, test, vi} from "vitest"
import NotificationBell from "./notification_bell.tsx"

describe("NotificationBell", () => {
  test("portals its hover tooltip so sidebar overflow cannot clip it", () => {
    render(
      <div className="overflow-hidden">
        <NotificationBell
          compact
          id="server-notification-bell"
          onToggle={vi.fn()}
          scopeLabel="Libera Chat"
          state={{kind: "enabled"}}
        />
      </div>
    )

    const button = screen.getByRole("button", {name: "Mute mention notifications for Libera Chat"})
    fireEvent.mouseEnter(button.parentElement as HTMLElement)

    const tooltip = screen.getByRole("tooltip")
    expect(tooltip).toHaveTextContent("Mention notifications are on for Libera Chat.")
    expect(tooltip).toHaveStyle({position: "fixed"})
    expect(tooltip.closest("[data-floating-ui-portal]")).not.toBeNull()
    expect(button).toHaveAttribute("aria-describedby", tooltip.id)

    fireEvent.mouseLeave(button.parentElement as HTMLElement)
    expect(screen.queryByRole("tooltip")).not.toBeInTheDocument()
  })

  test("shows the unavailable reason when a disabled bell is hovered", () => {
    render(
      <NotificationBell
        id="channel-notification-bell"
        onToggle={vi.fn()}
        scopeLabel="#elixir"
        state={{kind: "unavailable", reason: "Notifications require HTTPS or localhost."}}
      />
    )

    const button = screen.getByRole("button")
    fireEvent.mouseEnter(button.parentElement as HTMLElement)

    expect(screen.getByRole("tooltip")).toHaveTextContent("Notifications require HTTPS or localhost.")
  })
})
