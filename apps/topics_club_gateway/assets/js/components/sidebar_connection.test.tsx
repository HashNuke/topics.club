import {render, screen} from "@testing-library/react"
import {describe, expect, test, vi} from "vitest"
import SidebarConnection from "./sidebar_connection.tsx"

describe("SidebarConnection", () => {
  test("shows ordinary unread counts for joined channels", () => {
    const channel = {
      id: "channel:2",
      buffer_type: "channel",
      channel: "#elixir",
      unread_count: 3,
      mention_count: 0,
    }

    render(
      <SidebarConnection
        activeChannel={{id: "channel:1", channel: "#general"}}
        activeServer={{id: "server:1", channels: []}}
        connection={{
          id: "server:1",
          server_connection_id: 1,
          name: "Libera",
          host: "irc.libera.chat",
          channels: [channel],
        }}
        notificationDeviceState={{capability: "granted", configured: true, loading: false, subscribed: true}}
        notificationSavingIds={new Set()}
        onEditServer={vi.fn()}
        onLeaveServer={vi.fn()}
        onSelectChannel={vi.fn()}
        onSelectServer={vi.fn()}
        onToggleServerNotifications={vi.fn()}
        view="chat"
      />
    )

    expect(screen.getByLabelText("3 unread messages in #elixir")).toBeInTheDocument()
  })
})
