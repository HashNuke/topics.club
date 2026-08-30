import {describe, expect, test} from "vitest"
import {fallbackConnectionIssue, latestConnectionIssue} from "./connection_issue.ts"

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
})
