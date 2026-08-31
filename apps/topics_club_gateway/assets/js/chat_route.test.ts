import {describe, expect, test} from "vitest"
import {bufferPath, directoryPath, discoverPath, readChatRoute, selectRouteBuffer} from "./chat_route.ts"

const connections = [{
  id: "server:42",
  server_connection_id: 42,
  host: "irc.example.test",
  channels: [
    {id: "channel:7", channel: "#elixir"},
    {id: "direct:8", channel: "Akash"},
  ],
}]

describe("chat routes", () => {
  test("round-trips server, channel, direct-message, and directory paths", () => {
    expect(bufferPath(42)).toBe("/chat/42")
    expect(bufferPath(42, {channel: "#elixir"})).toBe("/chat/42/%23elixir")
    expect(bufferPath(42, {channel: "Akash"})).toBe("/chat/42/Akash")
    expect(directoryPath(42, 2, "beam tools")).toBe("/chat/42/%2Flist?p=2&q=beam+tools")

    expect(readChatRoute({pathname: "/chat/42/%23elixir", search: ""} as Location)).toEqual({kind: "buffer", connectionId: "42", target: "#elixir"})
    expect(readChatRoute({pathname: "/chat/42/%2Flist", search: "?p=2&q=beam+tools"} as Location)).toEqual({kind: "directory", connectionId: "42", page: 2, query: "beam tools"})
  })

  test("builds and parses all-server and connection-scoped discovery routes", () => {
    expect(discoverPath(null, 3, "linux")).toBe("/chat/discover/all?p=3&q=linux")
    expect(discoverPath(42)).toBe("/chat/discover/42")
    expect(readChatRoute({pathname: "/chat/discover/all", search: "?p=3&q=linux"} as Location)).toEqual({kind: "discover", connectionId: null, page: 3, query: "linux"})
    expect(readChatRoute({pathname: "/chat/discover/42", search: ""} as Location)).toEqual({kind: "discover", connectionId: "42", page: 1, query: ""})
  })

  test("resolves deep links against the authoritative bootstrap buffers", () => {
    expect(selectRouteBuffer(connections, {kind: "buffer", connectionId: "42", target: "#ELIXIR"})).toEqual({activeChannelId: "channel:7", activeServerId: "server:42", view: "chat"})
    expect(selectRouteBuffer(connections, {kind: "buffer", connectionId: "42", target: "akash"})).toEqual({activeChannelId: "direct:8", activeServerId: "server:42", view: "chat"})
    expect(selectRouteBuffer(connections, {kind: "buffer", connectionId: "42", target: null})).toEqual({activeChannelId: null, activeServerId: "server:42", view: "server"})
  })
})
