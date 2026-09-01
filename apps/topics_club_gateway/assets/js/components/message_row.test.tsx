import {render, screen} from "@testing-library/react"
import {describe, expect, test} from "vitest"
import MessageRow from "./message_row.tsx"

describe("MessageRow", () => {
  test("shows the IRC reason for a failed command", () => {
    render(
      <MessageRow
        message={{
          id: "message-command-failed",
          body: "JOIN #startups",
          kind: "command",
          nick: null,
          metadata: {
            command_status: "failed",
            error: "Cannot join channel (+r) - you need to be identified with services",
          },
        }}
      />
    )

    expect(screen.getByText("JOIN #startups")).toBeInTheDocument()
    expect(screen.getByRole("alert")).toHaveTextContent(
      "Cannot join channel (+r) - you need to be identified with services"
    )
  })
})
