import {render, screen} from "@testing-library/react"
import {describe, expect, test} from "vitest"
import {ManualJoinDialog} from "./server_dialogs.tsx"

describe("ManualJoinDialog", () => {
  test("starts with an empty server and no auto-join channels", () => {
    render(<ManualJoinDialog onClose={() => {}} onJoin={() => {}} />)

    const serverInput = screen.getByLabelText("Server")

    expect(serverInput).toHaveValue("")
    expect(serverInput).toHaveAttribute("placeholder", "irc.example.com")
    expect(serverInput).toHaveClass("placeholder:text-slate-600")
    expect(screen.getByLabelText("Auto-join channels")).toHaveValue("")
  })
})
