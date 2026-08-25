import {afterEach, describe, expect, test} from "vitest"
import {backendTopicFor, numericId, requestedTopicId, topicForRequestedId} from "./topic_navigation.js"

afterEach(() => window.history.pushState({}, "", "/"))

describe("topic navigation", () => {
  test("recognizes integer topic ids", () => {
    expect(numericId("42")).toBe(42)
    expect(numericId("not-an-id")).toBeNull()
  })

  test("matches a normalized topic to its backend record", () => {
    const topics = [{id: 42, channel: "#elixir", server_host: "irc.example.net", server_port: 6697}]
    expect(backendTopicFor({channel: "#elixir", server_host: "irc.example.net", server_port: 6697}, topics)).toEqual(topics[0])
  })

  test("finds requested topics by equivalent string ids", () => {
    const topic = {id: 42, channel: "#elixir"}
    expect(topicForRequestedId("42", [topic])).toBe(topic)
    expect(topicForRequestedId("7", [topic])).toBeNull()
  })

  test("reads the requested topic from the current URL", () => {
    window.history.pushState({}, "", "/chat?topic=42")
    expect(requestedTopicId()).toBe("42")
  })
})
