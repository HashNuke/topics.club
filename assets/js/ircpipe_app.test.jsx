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

function mockBootstrapFetch() {
  vi.spyOn(globalThis, "fetch").mockImplementation(async (path) => {
    if (path === "/api/bootstrap") {
      return {
        ok: true,
        json: async () => ({
          user: {id: 1, email: "mira@example.com", message_retention_days: 3},
          notification_state: "default",
          server_time: "2026-05-13T10:00:00Z",
          connections: [
            {
              id: 42,
              name: "local",
              host: "127.0.0.1",
              port: 6667,
              use_tls: false,
              nickname: "mira",
              status: "connected",
              channels: [7],
            },
          ],
          buffers: [
            {
              buffer_id: "server:42",
              buffer_type: "server",
              server_connection_id: 42,
              title: "127.0.0.1",
              subtitle: "local",
              status: "connected",
              unread_count: 0,
              mention_count: 0,
            },
            {
              buffer_id: "channel:7",
              buffer_type: "channel",
              server_connection_id: 42,
              channel_membership_id: 7,
              title: "#testing",
              subtitle: "on 127.0.0.1",
              status: "connected",
              unread_count: 1,
              mention_count: 0,
            },
          ],
          active_buffer_id: "channel:7",
          messages_by_buffer: {
            "channel:7": [
              {
                id: 99,
                buffer_id: "channel:7",
                nick: "akash",
                body: "loaded from bootstrap",
                kind: "message",
                mentioned: false,
                occurred_at: "2026-05-13T10:00:00Z",
              },
            ],
          },
          users_by_buffer: {"channel:7": []},
          topics: demoTopics,
        }),
      }
    }

    return {
      ok: true,
      json: async () => ({topics: demoTopics}),
    }
  })
}

describe("IrcpipeApp UI prototype", () => {
  test("shows topic-first landing cards with channel and server labels", async () => {
    mockTopicsFetch()

    render(<IrcpipeApp currentUser={null} developerOauth={true} />)

    expect(await screen.findByRole("heading", {name: "Community chat"})).toBeInTheDocument()
    expect(screen.getByRole("button", {name: /#elixir/i})).toHaveTextContent("on 127.0.0.1")
    expect(screen.getByRole("link", {name: "Open chat"})).toHaveAttribute("href", "/chat")
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
      "/auth/developer?topic=local-phoenix"
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
    expect(screen.getByText("on 127.0.0.1")).toBeInTheDocument()
    expect(screen.getByText(/placeholder chat until the IRC backend is wired/i)).toBeInTheDocument()
  })

  test("loads the authenticated chat shell from bootstrap", async () => {
    mockBootstrapFetch()

    render(<IrcpipeApp currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}} developerOauth={true} />)

    expect(await screen.findByRole("heading", {name: "#testing"})).toBeInTheDocument()
    expect(screen.getByText("loaded from bootstrap")).toBeInTheDocument()

    const nav = screen.getByRole("navigation", {name: "Joined topics"})
    expect(within(nav).getByText("local")).toBeInTheDocument()
    expect(within(nav).getByText("#testing")).toBeInTheDocument()
    expect(globalThis.fetch).toHaveBeenCalledWith("/api/bootstrap", expect.objectContaining({credentials: "same-origin"}))
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

    await user.click(screen.getByRole("button", {name: "local"}))

    expect(screen.getByRole("heading", {name: "127.0.0.1", level: 2})).toBeInTheDocument()
    expect(screen.getByText("Server buffer")).toBeInTheDocument()
    expect(screen.getByText(/NickServ/i)).toBeInTheDocument()
    expect(screen.getByText(/ChanServ/i)).toBeInTheDocument()
  })

  test("shows slash command suggestions from the chat composer", async () => {
    const user = userEvent.setup()
    mockTopicsFetch()

    render(<IrcpipeApp currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}} developerOauth={true} />)

    await user.type(screen.getByLabelText("Message composer"), "/jo")

    const suggestions = screen.getByRole("listbox", {name: "Slash command suggestions"})
    expect(within(suggestions).getByRole("option", {name: /\/join/i})).toBeInTheDocument()
  })

  test("keeps slash command suggestions hidden for normal messages", async () => {
    const user = userEvent.setup()
    mockTopicsFetch()

    render(<IrcpipeApp currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}} developerOauth={true} />)

    await user.type(screen.getByLabelText("Message composer"), "hello /join")

    expect(screen.queryByRole("listbox", {name: "Slash command suggestions"})).not.toBeInTheDocument()
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

    expect(await screen.findByRole("heading", {name: "Community chat"})).toBeInTheDocument()
    expect(screen.getByRole("link", {name: "Open chat"})).toHaveAttribute("href", "/chat")
    expect(screen.queryByRole("navigation", {name: "Joined topics"})).not.toBeInTheDocument()
  })

  test("prototype topics do not reference public IRC servers", () => {
    expect(demoTopics.map((topic) => topic.server_host)).toEqual(demoTopics.map(() => "127.0.0.1"))
    expect(demoTopics.map((topic) => topic.use_tls)).toEqual(demoTopics.map(() => false))
  })
})
