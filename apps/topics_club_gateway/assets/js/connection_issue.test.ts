import {describe, expect, test} from "vitest"
import {
  connectionIssueGuidance,
  fallbackConnectionIssue,
  latestConnectionIssue,
  randomIrcNickname,
} from "./connection_issue.ts"

describe("connection issues", () => {
  test("finds the most recent valid structured issue", () => {
    expect(latestConnectionIssue([
      {nick: null, body: "older", metadata: {connection_issue: {code: "old"}}},
      {
        nick: null,
        body: "invalid nickname",
        metadata: {
          connection_issue: {
            code: "invalid_nickname",
            title: "Nickname is not valid",
            summary: "Choose another nickname.",
            edit_focus: "nickname",
          },
        },
      },
    ])).toMatchObject({code: "invalid_nickname", edit_focus: "nickname"})
  })

  test("supplies a generic remedy for older unstructured errors", () => {
    expect(fallbackConnectionIssue()).toMatchObject({
      code: "connection_failed",
      edit_focus: "connection",
    })
  })

  test("replaces repeated nickname errors with actionable guidance", () => {
    expect(connectionIssueGuidance({
      code: "nickname_in_use",
      title: "Nickname is already in use",
      summary: "Nickname is already in use.",
      edit_focus: "nickname",
    })).toBe("Use a random nickname and reconnect now, or edit the connection to choose one yourself.")
  })

  test("generates a nickname that is safe for IRC registration", () => {
    expect(randomIrcNickname()).toMatch(/^guest_[a-z0-9]{6}$/)
  })
})
