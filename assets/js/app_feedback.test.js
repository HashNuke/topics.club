import {describe, expect, test} from "vitest"
import {channelDirectoryError, commandErrorMessage} from "./app_feedback.ts"

describe("commandErrorMessage", () => {
  test("uses structured backend messages and usage", () => {
    expect(commandErrorMessage({error: {message: "Missing target.", usage: "/msg <nick> <message>"}})).toBe(
      "Missing target. Usage: /msg <nick> <message>"
    )
  })

  test("maps known reasons and provides a fallback", () => {
    expect(commandErrorMessage({reason: "not_connected"})).toBe(
      "Reconnect to the IRC server before running this command."
    )
    expect(commandErrorMessage({reason: "unexpected"})).toBe("The IRC command could not be sent.")
  })
})

describe("channelDirectoryError", () => {
  test("maps directory failure reasons", () => {
    expect(channelDirectoryError("list_timeout")).toBe("The server took too long to return its channel list.")
    expect(channelDirectoryError("unexpected")).toBe("The server could not return its channel list. Try again shortly.")
  })
})
