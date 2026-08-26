import React from "react"
import {render, screen} from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import {describe, expect, test, vi} from "vitest"
import {DirectMessageActionMenu, ServerActionMenu} from "./sidebar_action_menus.tsx"

describe("sidebar action menus", () => {
  test("supports arrow navigation, escape, focus restoration, and activation", async () => {
    const user = userEvent.setup()
    const onEdit = vi.fn()

    render(
      <ServerActionMenu
        server={{id: "server:1", name: "Libera", host: "irc.example.test", channels: []}}
        onEdit={onEdit}
        onLeave={() => {}}
      />
    )

    const trigger = screen.getByRole("button", {name: "Server actions for Libera"})
    trigger.focus()
    await user.keyboard("{ArrowDown}")
    expect(screen.getByRole("menuitem", {name: "Connect or reconnect"})).toHaveFocus()

    await user.keyboard("{ArrowDown}")
    expect(screen.getByRole("menuitem", {name: "Edit connection"})).toHaveFocus()
    await user.keyboard("{Enter}")
    expect(onEdit).toHaveBeenCalledOnce()
    expect(trigger).toHaveFocus()

    await user.click(trigger)
    await user.keyboard("{End}")
    expect(screen.getByRole("menuitem", {name: "Leave server"})).toHaveFocus()
    await user.keyboard("{Escape}")
    expect(screen.queryByRole("menu")).not.toBeInTheDocument()
    expect(trigger).toHaveFocus()
  })

  test("closes when focus moves with tab or the user clicks outside", async () => {
    const user = userEvent.setup()
    render(
      <div>
        <DirectMessageActionMenu
          channel={{id: "direct:8", channel: "akash", buffer_type: "direct_message"}}
          onClose={() => {}}
        />
        <button type="button">Outside</button>
      </div>
    )

    const trigger = screen.getByRole("button", {name: "Private message actions for akash"})
    await user.click(trigger)
    await user.keyboard("{Tab}")
    expect(screen.queryByRole("menu")).not.toBeInTheDocument()

    await user.click(trigger)
    await user.click(screen.getByRole("button", {name: "Outside"}))
    expect(screen.queryByRole("menu")).not.toBeInTheDocument()
  })
})
