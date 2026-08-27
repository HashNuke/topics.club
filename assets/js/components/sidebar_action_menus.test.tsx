import React from "react"
import {act, fireEvent, render, screen} from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import {describe, expect, test, vi} from "vitest"
import {ChannelActionMenu, DirectMessageActionMenu, ServerActionMenu} from "./sidebar_action_menus.tsx"

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

    await user.keyboard("{ArrowUp}")
    expect(screen.getByRole("menuitem", {name: "Leave server"})).toHaveFocus()
    await user.keyboard("{ArrowDown}")
    expect(screen.getByRole("menuitem", {name: "Connect or reconnect"})).toHaveFocus()
    await user.keyboard("{End}")
    expect(screen.getByRole("menuitem", {name: "Leave server"})).toHaveFocus()
    await user.keyboard("{Home}")
    expect(screen.getByRole("menuitem", {name: "Connect or reconnect"})).toHaveFocus()
    await user.keyboard("{ArrowDown}")
    expect(screen.getByRole("menuitem", {name: "Edit connection"})).toHaveFocus()
    await user.keyboard("{Enter}")
    expect(onEdit).toHaveBeenCalledOnce()
    expect(trigger).toHaveFocus()

    await user.click(trigger)
    await user.keyboard("{Escape}")
    expect(screen.queryByRole("menu")).not.toBeInTheDocument()
    expect(trigger).toHaveFocus()
  })

  test("closes into logical tab order in both directions or on an outside click", async () => {
    const user = userEvent.setup()
    render(
      <div>
        <button type="button">Previous</button>
        <DirectMessageActionMenu
          channel={{id: "direct:8", channel: "akash", buffer_type: "direct_message"}}
          onClose={() => {}}
        />
        <button type="button">Next</button>
      </div>
    )

    const trigger = screen.getByRole("button", {name: "Private message actions for akash"})
    await user.click(trigger)
    await user.keyboard("{Tab}")
    expect(screen.queryByRole("menu")).not.toBeInTheDocument()
    expect(screen.getByRole("button", {name: "Next"})).toHaveFocus()

    await user.click(trigger)
    await user.keyboard("{Shift>}{Tab}{/Shift}")
    expect(screen.queryByRole("menu")).not.toBeInTheDocument()
    expect(screen.getByRole("button", {name: "Previous"})).toHaveFocus()

    await user.click(trigger)
    await user.click(screen.getByRole("button", {name: "Next"}))
    expect(screen.queryByRole("menu")).not.toBeInTheDocument()
  })

  test("keeps only one channel action menu open", () => {
    render(
      <div>
        <ChannelActionMenu channel={{id: "channel:1", channel: "#one"}} onCopyChannel={() => {}} />
        <ChannelActionMenu channel={{id: "channel:2", channel: "#two"}} onCopyChannel={() => {}} />
      </div>
    )

    const first = screen.getByRole("button", {name: "Channel actions for #one"})
    const second = screen.getByRole("button", {name: "Channel actions for #two"})
    fireEvent.click(first)
    fireEvent.click(second)

    expect(first).toHaveAttribute("aria-expanded", "false")
    expect(second).toHaveAttribute("aria-expanded", "true")
    expect(screen.getAllByRole("menu")).toHaveLength(1)
  })

  test("portals menus outside an overflowing sidebar", async () => {
    const user = userEvent.setup()
    render(
      <nav data-testid="scrolling-sidebar" style={{overflowY: "auto"}}>
        <ChannelActionMenu channel={{id: "channel:1", channel: "#one"}} onCopyChannel={() => {}} />
      </nav>
    )

    await user.click(screen.getByRole("button", {name: "Channel actions for #one"}))

    const sidebar = screen.getByTestId("scrolling-sidebar")
    expect(sidebar).not.toContainElement(screen.getByRole("menu"))
    const menu = screen.getByRole("menu")
    expect(document.body).toContainElement(menu)
    expect(menu).toHaveClass("z-[60]")
  })

  test("does not steal focus again when an open menu rerenders", async () => {
    const user = userEvent.setup()
    const {rerender} = render(
      <div>
        <ChannelActionMenu channel={{id: "channel:1", channel: "#one"}} onCopyChannel={() => {}} />
        <input aria-label="Composer" />
      </div>
    )

    await user.click(screen.getByRole("button", {name: "Channel actions for #one"}))
    const composer = screen.getByLabelText("Composer")
    composer.focus()
    rerender(
      <div>
        <ChannelActionMenu channel={{id: "channel:1", channel: "#one"}} onCopyChannel={() => {}} />
        <input aria-label="Composer" />
      </div>
    )
    await act(async () => {})

    expect(composer).toHaveFocus()
    expect(screen.getByRole("menu")).toBeInTheDocument()
  })
})
