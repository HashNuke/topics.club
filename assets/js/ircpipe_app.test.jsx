import React from "react"
import {describe, expect, test, vi} from "vitest"
import {render, screen, waitFor, within} from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import IrcpipeApp, {demoTopics, visibleTimelineMessages} from "./ircpipe_app.jsx"

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

function mockJoinTopicFetch() {
  const topics = [
    {
      id: 101,
      name: "#backend",
      description: "Backend implementation work.",
      server_host: "127.0.0.1",
      server_port: 6667,
      use_tls: false,
      channel: "#backend",
    },
  ]

  vi.spyOn(globalThis, "fetch").mockImplementation(async (path) => {
    if (path === "/api/bootstrap") {
      return {
        ok: true,
        json: async () => ({
          connections: [],
          buffers: [],
          messages_by_buffer: {},
          users_by_buffer: {},
          topics,
          notification_state: "default",
        }),
      }
    }

    if (path === "/api/topics/101/join") {
      return {
        ok: true,
        json: async () => ({
          topic: topics[0],
          connection: {
            id: 55,
            name: "127.0.0.1",
            host: "127.0.0.1",
            port: 6667,
            use_tls: false,
            nickname: "mira",
            status: "connected",
          },
          buffer: {
            buffer_id: "channel:88",
            buffer_type: "channel",
            server_connection_id: 55,
            channel_membership_id: 88,
            title: "#backend",
            subtitle: "on 127.0.0.1",
            status: "connected",
            unread_count: 0,
            mention_count: 0,
          },
        }),
      }
    }

    return {
      ok: true,
      json: async () => ({topics}),
    }
  })
}

function fakeRealtimeClient(pushImpl) {
  const client = {
    connect: vi.fn(() => client),
    disconnect: vi.fn(),
    push: pushImpl,
  }

  return client
}

describe("IrcpipeApp UI prototype", () => {
  test("caps rendered messages only while the reader is near the bottom", () => {
    const messages = Array.from({length: 6}, (_, index) => ({id: index + 1, body: `message ${index + 1}`}))

    expect(visibleTimelineMessages(messages, false, 3).map((message) => message.id)).toEqual([4, 5, 6])
    expect(visibleTimelineMessages(messages, true, 3).map((message) => message.id)).toEqual([1, 2, 3, 4, 5, 6])
  })

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

  test("joins numeric backend topics through the topic join API", async () => {
    const user = userEvent.setup()
    mockJoinTopicFetch()

    render(<IrcpipeApp currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}} developerOauth={true} />)

    await user.click(screen.getByRole("button", {name: /discover/i}))
    await user.click(await screen.findByRole("button", {name: /#backend/i}))

    expect(await screen.findByRole("heading", {name: "#backend"})).toBeInTheDocument()
    expect(screen.getByText("on 127.0.0.1")).toBeInTheDocument()
    expect(globalThis.fetch).toHaveBeenCalledWith(
      "/api/topics/101/join",
      expect.objectContaining({method: "POST", credentials: "same-origin"})
    )
  })

  test("sends channel messages through the realtime client and replaces pending message", async () => {
    const user = userEvent.setup()
    mockBootstrapFetch()
    const push = vi.fn().mockResolvedValue({
      client_message_id: "client-reply",
      message: {
        id: 100,
        buffer_id: "channel:7",
        nick: "mira",
        body: "sent through socket",
        kind: "message",
        mentioned: false,
        occurred_at: "2026-05-13T10:01:00Z",
      },
    })
    const client = fakeRealtimeClient(push)
    let realtimeHandlers

    render(
      <IrcpipeApp
        currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}}
        developerOauth={true}
        realtimeClientFactory={({handlers}) => {
          realtimeHandlers = handlers
          return client
        }}
      />
    )

    expect(await screen.findByRole("heading", {name: "#testing"})).toBeInTheDocument()
    realtimeHandlers.onOpen()

    await user.type(screen.getByLabelText("Message composer"), "sent through socket")
    await user.click(screen.getByRole("button", {name: "Send"}))

    expect(push).toHaveBeenCalledWith(
      "message:send",
      expect.objectContaining({
        buffer_id: "channel:7",
        body: "sent through socket",
        client_message_id: expect.stringMatching(/^client-/),
      })
    )
    expect(await screen.findByText("sent through socket")).toBeInTheDocument()
    expect(screen.queryByText("sending")).not.toBeInTheDocument()
  })

  test("marks realtime channel send failures in the timeline", async () => {
    const user = userEvent.setup()
    mockBootstrapFetch()
    const client = fakeRealtimeClient(vi.fn().mockRejectedValue({reason: "not_connected"}))
    let realtimeHandlers

    render(
      <IrcpipeApp
        currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}}
        developerOauth={true}
        realtimeClientFactory={({handlers}) => {
          realtimeHandlers = handlers
          return client
        }}
      />
    )

    expect(await screen.findByRole("heading", {name: "#testing"})).toBeInTheDocument()
    realtimeHandlers.onOpen()

    await user.type(screen.getByLabelText("Message composer"), "will fail")
    await user.click(screen.getByRole("button", {name: "Send"}))

    expect(await screen.findByRole("button", {name: "Retry"})).toBeInTheDocument()
  })

  test("retries failed realtime channel messages", async () => {
    const user = userEvent.setup()
    mockBootstrapFetch()
    const push = vi
      .fn()
      .mockRejectedValueOnce({reason: "not_connected"})
      .mockResolvedValueOnce({
        message: {
          id: 101,
          buffer_id: "channel:7",
          nick: "mira",
          body: "try again",
          kind: "message",
          mentioned: false,
          occurred_at: "2026-05-13T10:02:00Z",
        },
      })
    const client = fakeRealtimeClient(push)
    let realtimeHandlers

    render(
      <IrcpipeApp
        currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}}
        developerOauth={true}
        realtimeClientFactory={({handlers}) => {
          realtimeHandlers = handlers
          return client
        }}
      />
    )

    expect(await screen.findByRole("heading", {name: "#testing"})).toBeInTheDocument()
    realtimeHandlers.onOpen()

    await user.type(screen.getByLabelText("Message composer"), "try again")
    await user.click(screen.getByRole("button", {name: "Send"}))
    await user.click(await screen.findByRole("button", {name: "Retry"}))

    await waitFor(() => expect(push).toHaveBeenCalledTimes(2))
    expect(push).toHaveBeenLastCalledWith(
      "message:send",
      expect.objectContaining({
        buffer_id: "channel:7",
        body: "try again",
        client_message_id: expect.stringMatching(/^client-/),
      })
    )
    expect(await screen.findByText("try again")).toBeInTheDocument()
    expect(screen.queryByRole("button", {name: "Retry"})).not.toBeInTheDocument()
  })

  test("keeps channel drafts unsent while the realtime socket is offline", async () => {
    const user = userEvent.setup()
    mockBootstrapFetch()
    const push = vi.fn()
    const client = fakeRealtimeClient(push)

    render(
      <IrcpipeApp
        currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}}
        developerOauth={true}
        realtimeClientFactory={() => client}
      />
    )

    expect(await screen.findByRole("heading", {name: "#testing"})).toBeInTheDocument()

    const composer = screen.getByLabelText("Message composer")
    await user.type(composer, "still drafting")

    expect(screen.getByRole("button", {name: "Send"})).toBeDisabled()
    expect(push).not.toHaveBeenCalled()
    expect(composer).toHaveValue("still drafting")
  })

  test("shows degraded connection health when the realtime join fails", async () => {
    mockBootstrapFetch()
    let realtimeHandlers
    const client = fakeRealtimeClient(vi.fn())

    render(
      <IrcpipeApp
        currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}}
        developerOauth={true}
        realtimeClientFactory={({handlers}) => {
          realtimeHandlers = handlers
          return client
        }}
      />
    )

    expect(await screen.findByRole("heading", {name: "#testing"})).toBeInTheDocument()

    realtimeHandlers.onJoinError({reason: "unauthorized"})

    await waitFor(() => expect(screen.getByLabelText("Connection degraded")).toBeInTheDocument())
  })

  test("updates connection health from socket lifecycle callbacks", async () => {
    mockBootstrapFetch()
    let realtimeHandlers
    const client = fakeRealtimeClient(vi.fn())

    render(
      <IrcpipeApp
        currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}}
        developerOauth={true}
        realtimeClientFactory={({handlers}) => {
          realtimeHandlers = handlers
          return client
        }}
      />
    )

    expect(await screen.findByRole("heading", {name: "#testing"})).toBeInTheDocument()

    realtimeHandlers.onOpen()
    await waitFor(() => expect(screen.getByLabelText("Connection connected")).toBeInTheDocument())

    realtimeHandlers.onClose()
    await waitFor(() => expect(screen.getByLabelText("Connection reconnecting")).toBeInTheDocument())

    realtimeHandlers.onError()
    await waitFor(() => expect(screen.getByLabelText("Connection degraded")).toBeInTheDocument())
  })

  test("updates the user sidebar from presence sync events", async () => {
    mockBootstrapFetch()
    let realtimeHandlers
    const client = fakeRealtimeClient(vi.fn())

    render(
      <IrcpipeApp
        currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}}
        developerOauth={true}
        realtimeClientFactory={({handlers}) => {
          realtimeHandlers = handlers
          return client
        }}
      />
    )

    expect(await screen.findByRole("heading", {name: "#testing"})).toBeInTheDocument()

    realtimeHandlers.onPresenceSync({
      buffer_id: "channel:7",
      users: [
        {nick: "mira", role: "op", status: "online"},
        {nick: "akash", role: "user", status: "online"},
      ],
    })

    const people = screen.getByRole("complementary", {name: "People here"})
    await waitFor(() => expect(within(people).getByText("akash")).toBeInTheDocument())
    expect(within(people).getByText("mira")).toBeInTheDocument()
  })

  test("applies incremental presence diff events to the user sidebar", async () => {
    mockBootstrapFetch()
    let realtimeHandlers
    const client = fakeRealtimeClient(vi.fn())

    render(
      <IrcpipeApp
        currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}}
        developerOauth={true}
        realtimeClientFactory={({handlers}) => {
          realtimeHandlers = handlers
          return client
        }}
      />
    )

    expect(await screen.findByRole("heading", {name: "#testing"})).toBeInTheDocument()

    realtimeHandlers.onPresenceSync({
      buffer_id: "channel:7",
      users: [{nick: "mira", role: "op", status: "online"}],
    })
    realtimeHandlers.onPresenceDiff({
      buffer_id: "channel:7",
      diff: {action: "join", user: {nick: "akash", role: "user", status: "online"}},
    })

    const people = screen.getByRole("complementary", {name: "People here"})
    await waitFor(() => expect(within(people).getByText("akash")).toBeInTheDocument())

    realtimeHandlers.onPresenceDiff({buffer_id: "channel:7", diff: {action: "nick", old_nick: "akash", new_nick: "ak"}})
    await waitFor(() => expect(within(people).getByText("ak")).toBeInTheDocument())

    realtimeHandlers.onPresenceDiff({buffer_id: "channel:7", diff: {action: "part", nick: "ak"}})
    await waitFor(() => expect(within(people).queryByText("ak")).not.toBeInTheDocument())
  })

  test("removes a channel buffer after a realtime leave event", async () => {
    mockBootstrapFetch()
    let realtimeHandlers
    const client = fakeRealtimeClient(vi.fn())

    render(
      <IrcpipeApp
        currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}}
        developerOauth={true}
        realtimeClientFactory={({handlers}) => {
          realtimeHandlers = handlers
          return client
        }}
      />
    )

    expect(await screen.findByRole("heading", {name: "#testing"})).toBeInTheDocument()

    realtimeHandlers.onBufferLeft({
      type: "buffer:left",
      buffer_id: "channel:7",
      server_connection_id: 42,
      channel_membership_id: 7,
    })

    expect(await screen.findByRole("heading", {name: "127.0.0.1", level: 2})).toBeInTheDocument()
    expect(screen.queryByRole("button", {name: /#testing/})).not.toBeInTheDocument()
    expect(screen.queryByRole("complementary", {name: "People here"})).not.toBeInTheDocument()
  })

  test("renders realtime server buffer messages", async () => {
    const user = userEvent.setup()
    mockBootstrapFetch()
    let realtimeHandlers
    const client = fakeRealtimeClient(vi.fn())

    render(
      <IrcpipeApp
        currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}}
        developerOauth={true}
        realtimeClientFactory={({handlers}) => {
          realtimeHandlers = handlers
          return client
        }}
      />
    )

    expect(await screen.findByRole("heading", {name: "#testing"})).toBeInTheDocument()
    await user.click(screen.getByRole("button", {name: "local"}))

    realtimeHandlers.onBufferMessage({
      type: "buffer:message",
      buffer_id: "server:42",
      id: 204,
      nick: "127.0.0.1",
      body: "MOTD starts here",
      kind: "notice",
      occurred_at: "2026-05-13T10:03:00Z",
    })

    expect(await screen.findByText("MOTD starts here")).toBeInTheDocument()
  })

  test("caps large user groups and expands them on request", async () => {
    const user = userEvent.setup()
    mockBootstrapFetch()
    let realtimeHandlers
    const client = fakeRealtimeClient(vi.fn())
    const manyUsers = Array.from({length: 12}, (_, index) => ({
      nick: `user${index + 1}`,
      role: "user",
      status: "online",
    }))

    render(
      <IrcpipeApp
        currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}}
        developerOauth={true}
        realtimeClientFactory={({handlers}) => {
          realtimeHandlers = handlers
          return client
        }}
      />
    )

    expect(await screen.findByRole("heading", {name: "#testing"})).toBeInTheDocument()

    realtimeHandlers.onPresenceSync({buffer_id: "channel:7", users: manyUsers})

    const people = screen.getByRole("complementary", {name: "People here"})
    await waitFor(() => expect(within(people).getByText("user10")).toBeInTheDocument())
    expect(within(people).queryByText("user11")).not.toBeInTheDocument()

    await user.click(within(people).getByRole("button", {name: "+2 more"}))

    expect(within(people).getByText("user12")).toBeInTheDocument()
  })

  test("shows browser notifications for hidden-tab mention events", async () => {
    mockBootstrapFetch()
    let realtimeHandlers
    const client = fakeRealtimeClient(vi.fn())
    const NotificationMock = vi.fn()
    NotificationMock.permission = "granted"
    const originalNotification = window.Notification

    Object.defineProperty(window, "Notification", {value: NotificationMock, configurable: true})
    const originalVisibilityState = document.visibilityState
    Object.defineProperty(document, "visibilityState", {value: "hidden", configurable: true})

    try {
      render(
        <IrcpipeApp
          currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}}
          developerOauth={true}
          realtimeClientFactory={({handlers}) => {
            realtimeHandlers = handlers
            return client
          }}
        />
      )

      expect(await screen.findByRole("heading", {name: "#testing"})).toBeInTheDocument()

      realtimeHandlers.onNotificationMention({channel: "#testing", nick: "akash", body: "hello mira"})

      expect(NotificationMock).toHaveBeenCalledWith("#testing", {body: "akash: hello mira"})
    } finally {
      if (originalNotification) {
        Object.defineProperty(window, "Notification", {value: originalNotification, configurable: true})
      } else {
        delete window.Notification
      }
      Object.defineProperty(document, "visibilityState", {value: originalVisibilityState, configurable: true})
    }
  })

  test("does not show browser notifications while the chat tab is visible", async () => {
    mockBootstrapFetch()
    let realtimeHandlers
    const client = fakeRealtimeClient(vi.fn())
    const NotificationMock = vi.fn()
    NotificationMock.permission = "granted"
    const originalNotification = window.Notification

    Object.defineProperty(window, "Notification", {value: NotificationMock, configurable: true})
    const originalVisibilityState = document.visibilityState
    Object.defineProperty(document, "visibilityState", {value: "visible", configurable: true})

    try {
      render(
        <IrcpipeApp
          currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}}
          developerOauth={true}
          realtimeClientFactory={({handlers}) => {
            realtimeHandlers = handlers
            return client
          }}
        />
      )

      expect(await screen.findByRole("heading", {name: "#testing"})).toBeInTheDocument()

      realtimeHandlers.onNotificationMention({channel: "#testing", nick: "akash", body: "hello mira"})

      expect(NotificationMock).not.toHaveBeenCalled()
    } finally {
      if (originalNotification) {
        Object.defineProperty(window, "Notification", {value: originalNotification, configurable: true})
      } else {
        delete window.Notification
      }
      Object.defineProperty(document, "visibilityState", {value: originalVisibilityState, configurable: true})
    }
  })

  test("requests browser notification permission from the bell button", async () => {
    const user = userEvent.setup()
    mockBootstrapFetch()
    const requestPermission = vi.fn().mockResolvedValue("granted")
    const NotificationMock = vi.fn()
    NotificationMock.permission = "default"
    NotificationMock.requestPermission = requestPermission
    const originalNotification = window.Notification

    Object.defineProperty(window, "Notification", {value: NotificationMock, configurable: true})

    try {
      render(<IrcpipeApp currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}} developerOauth={true} />)

      expect(await screen.findByRole("heading", {name: "#testing"})).toBeInTheDocument()
      expect(requestPermission).not.toHaveBeenCalled()

      await user.click(screen.getByLabelText("Enable browser notifications"))

      expect(requestPermission).toHaveBeenCalledTimes(1)
      expect(await screen.findByLabelText("Enable browser notifications")).toHaveClass("text-emerald-200")
    } finally {
      if (originalNotification) {
        Object.defineProperty(window, "Notification", {value: originalNotification, configurable: true})
      } else {
        delete window.Notification
      }
    }
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
    expect(screen.queryByRole("complementary", {name: "People here"})).not.toBeInTheDocument()
    expect(screen.queryByRole("button", {name: "Show users"})).not.toBeInTheDocument()
  })

  test("shows slash command suggestions from the chat composer", async () => {
    const user = userEvent.setup()
    mockTopicsFetch()

    render(<IrcpipeApp currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}} developerOauth={true} />)

    await user.type(screen.getByLabelText("Message composer"), "/jo")

    const suggestions = screen.getByRole("listbox", {name: "Slash command suggestions"})
    expect(within(suggestions).getByRole("option", {name: /\/join/i})).toBeInTheDocument()
  })

  test("runs slash command submissions through the realtime client", async () => {
    const user = userEvent.setup()
    mockBootstrapFetch()
    const push = vi.fn().mockResolvedValue({command: {name: "join", args: ["#ops"]}})
    const client = fakeRealtimeClient(push)
    let realtimeHandlers

    render(
      <IrcpipeApp
        currentUser={{id: 1, email: "mira@example.com", message_retention_days: 3}}
        developerOauth={true}
        realtimeClientFactory={({handlers}) => {
          realtimeHandlers = handlers
          return client
        }}
      />
    )

    expect(await screen.findByRole("heading", {name: "#testing"})).toBeInTheDocument()
    realtimeHandlers.onOpen()

    await user.type(screen.getByLabelText("Message composer"), "/join #ops")
    await user.click(screen.getByRole("button", {name: "Send"}))

    expect(push).toHaveBeenCalledWith(
      "command:run",
      expect.objectContaining({
        input: "/join #ops",
        buffer_id: "channel:7",
      })
    )
    expect(await screen.findByText("Command accepted.")).toBeInTheDocument()
    expect(screen.queryByText("/join #ops")).not.toBeInTheDocument()
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
