import React from "react"
import {describe, expect, test, vi} from "vitest"
import {render, screen, within} from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import IrcpipeApp, {demoTopics} from "./ircpipe_app.jsx"

function mockTopicsFetch() {
  vi.spyOn(globalThis, "fetch").mockResolvedValue({
    ok: true,
    json: async () => ({topics: demoTopics}),
  })
}

describe("IrcpipeApp UI prototype", () => {
  test("shows topic-first landing cards with channel and server labels", async () => {
    mockTopicsFetch()

    render(<IrcpipeApp currentUser={null} developerOauth={true} />)

    expect(await screen.findByRole("heading", {name: "Choose a topic and land straight in the chat."})).toBeInTheDocument()
    expect(screen.getByRole("button", {name: /#elixir/i})).toHaveTextContent("on irc.libera.chat")
    expect(screen.getByRole("link", {name: "Developer OAuth"})).toHaveAttribute("href", "/auth/developer")
  })

  test("asks unauthenticated users to sign in before joining a topic", async () => {
    const user = userEvent.setup()
    mockTopicsFetch()

    render(<IrcpipeApp currentUser={null} developerOauth={true} />)

    await user.click(await screen.findByRole("button", {name: /#phoenix/i}))

    const dialog = screen.getByRole("dialog", {name: "Sign in to join"})

    expect(within(dialog).getByRole("heading", {name: "Sign in to join"})).toBeInTheDocument()
    expect(within(dialog).getByRole("link", {name: "Developer OAuth"})).toHaveAttribute(
      "href",
      "/auth/developer?topic=libera-phoenix"
    )
  })

  test("opens discover and joins a suggested topic in the app shell", async () => {
    const user = userEvent.setup()
    mockTopicsFetch()

    render(<IrcpipeApp currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}} developerOauth={true} />)

    await user.click(screen.getByRole("button", {name: /discover/i}))
    expect(screen.getByRole("heading", {name: "Discover topics"})).toBeInTheDocument()

    await user.click(screen.getByRole("button", {name: /#rust/i}))

    expect(screen.getByRole("heading", {name: "#rust"})).toBeInTheDocument()
    expect(screen.getByText("on irc.libera.chat")).toBeInTheDocument()
    expect(screen.getByText(/placeholder chat until the IRC backend is wired/i)).toBeInTheDocument()
  })

  test("lets signed-in users join their own server and channel", async () => {
    const user = userEvent.setup()
    mockTopicsFetch()

    render(<IrcpipeApp currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}} developerOauth={true} />)

    await user.click(screen.getByLabelText("Join another server"))
    await user.clear(screen.getByLabelText("Server"))
    await user.type(screen.getByLabelText("Server"), "irc.example.net")
    await user.clear(screen.getByLabelText("Auto-join channels"))
    await user.type(screen.getByLabelText("Auto-join channels"), "#music, ##deep")
    await user.click(screen.getByRole("button", {name: "Join"}))

    const nav = screen.getByRole("navigation", {name: "Joined topics"})
    expect(within(nav).getByText("irc.example.net")).toBeInTheDocument()
    expect(within(nav).getByText("#music")).toBeInTheDocument()
    expect(within(nav).getByText("##deep")).toBeInTheDocument()
    expect(screen.getByRole("heading", {name: "##deep"})).toBeInTheDocument()
  })

  test("opens a server buffer from the sidebar", async () => {
    const user = userEvent.setup()
    mockTopicsFetch()

    render(<IrcpipeApp currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}} developerOauth={true} />)

    await user.click(screen.getByRole("button", {name: /libera/i}))

    expect(screen.getByRole("heading", {name: "irc.libera.chat", level: 2})).toBeInTheDocument()
    expect(screen.getByText("Server buffer")).toBeInTheDocument()
    expect(screen.getByText(/NickServ/i)).toBeInTheDocument()
    expect(screen.getByText(/ChanServ/i)).toBeInTheDocument()
  })

  test("keeps signed-in users on the public landing page unless they open chat", async () => {
    mockTopicsFetch()

    render(
      <IrcpipeApp
        appMode="landing"
        currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}}
        developerOauth={true}
      />
    )

    expect(await screen.findByRole("heading", {name: "Choose a topic and land straight in the chat."})).toBeInTheDocument()
    expect(screen.getByRole("link", {name: "Open chat"})).toHaveAttribute("href", "/chat")
    expect(screen.queryByRole("navigation", {name: "Joined topics"})).not.toBeInTheDocument()
  })
})
