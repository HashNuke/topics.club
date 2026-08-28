import {render, screen} from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import {describe, expect, test, vi} from "vitest"
import MessageTimeline from "./message_timeline.tsx"

describe("MessageTimeline", () => {
  test("shows a loading skeleton before history arrives", () => {
    render(<MessageTimeline loading messages={[]} />)

    expect(screen.getByRole("status", {name: "Loading messages"})).toBeInTheDocument()
    expect(screen.queryByText("No messages yet")).not.toBeInTheDocument()
  })

  test("shows an empty state only after loading finishes", () => {
    render(<MessageTimeline messages={[]} />)

    expect(screen.getByText("No messages yet")).toBeInTheDocument()
    expect(screen.getByText("New activity will appear here.")).toBeInTheDocument()
  })

  test("renders history instead of the empty state", () => {
    render(
      <MessageTimeline
        messages={[{
          id: 1,
          nick: "mira",
          body: "restored from history",
          kind: "message",
          occurredAt: "2026-08-26T04:00:00Z",
        }]}
      />
    )

    expect(screen.getByText("restored from history")).toBeInTheDocument()
    expect(screen.queryByText("No messages yet")).not.toBeInTheDocument()
  })

  test("lets the user click a message nick to mention it", async () => {
    const user = userEvent.setup()
    const onMentionNick = vi.fn()

    render(
      <MessageTimeline
        messages={[{
          id: 1,
          nick: "akash",
          body: "hello",
          kind: "message",
          occurredAt: "2026-08-26T04:00:00Z",
        }]}
        onMentionNick={onMentionNick}
      />
    )

    await user.click(screen.getByRole("button", {name: "Mention akash"}))
    expect(onMentionNick).toHaveBeenCalledWith("akash")
  })

  test("does not render an inert nick button without a mention action", () => {
    render(
      <MessageTimeline
        messages={[{
          id: 2,
          nick: "akash",
          body: "hello",
          kind: "message",
          occurredAt: "2026-08-26T04:00:00Z",
        }]}
      />
    )

    expect(screen.getByText("akash")).toBeInTheDocument()
    expect(screen.queryByRole("button", {name: "Mention akash"})).not.toBeInTheDocument()
  })

  test("groups contiguous join and quit events", () => {
    render(
      <MessageTimeline
        messages={[
          {id: 1, nick: "lena", body: "lena joined #elixir.", kind: "join", occurredAt: "2026-08-26T04:00:00Z"},
          {id: 2, nick: "nora", body: "nora joined #elixir.", kind: "join", occurredAt: "2026-08-26T04:00:01Z"},
          {id: 3, nick: "max", body: "max quit.", kind: "quit", occurredAt: "2026-08-26T04:00:02Z"},
          {id: 4, nick: "sam", body: "sam quit.", kind: "quit", occurredAt: "2026-08-26T04:00:03Z"},
        ]}
      />
    )

    expect(screen.getByText("2 joined · 2 quit")).toBeInTheDocument()
    expect(screen.queryByText("lena joined #elixir.")).not.toBeInTheDocument()
    expect(screen.queryByText("sam quit.")).not.toBeInTheDocument()
  })

  test("does not group join and quit events across a chat message", () => {
    render(
      <MessageTimeline
        messages={[
          {id: 1, nick: "lena", body: "lena joined #elixir.", kind: "join", occurredAt: "2026-08-26T04:00:00Z"},
          {id: 2, nick: "max", body: "max quit.", kind: "quit", occurredAt: "2026-08-26T04:00:01Z"},
          {id: 3, nick: "mira", body: "hello between groups", kind: "message", occurredAt: "2026-08-26T04:00:02Z"},
          {id: 4, nick: "nora", body: "nora joined #elixir.", kind: "join", occurredAt: "2026-08-26T04:00:03Z"},
          {id: 5, nick: "sam", body: "sam quit.", kind: "quit", occurredAt: "2026-08-26T04:00:04Z"},
        ]}
      />
    )

    expect(screen.getAllByText("1 joined · 1 quit")).toHaveLength(2)
    expect(screen.getByText("hello between groups")).toBeInTheDocument()
  })

  test("keeps an isolated join or quit event unchanged", () => {
    render(
      <MessageTimeline
        messages={[
          {id: 1, nick: "lena", body: "lena joined #elixir.", kind: "join", occurredAt: "2026-08-26T04:00:00Z"},
          {id: 2, nick: "mira", body: "welcome", kind: "message", occurredAt: "2026-08-26T04:00:01Z"},
        ]}
      />
    )

    expect(screen.getByText("lena joined #elixir.")).toBeInTheDocument()
    expect(screen.queryByText("1 joined")).not.toBeInTheDocument()
  })
})
