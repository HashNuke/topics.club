import {render, screen} from "@testing-library/react"
import {describe, expect, test} from "vitest"
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
})
