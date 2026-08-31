import {describe, expect, test} from "vitest"
import {selectPreferredBuffer} from "./active_buffer_preference.ts"

const connections = [
  {
    id: "server:42",
    host: "irc.example.test",
    channels: [
      {id: "channel:7", channel: "#first"},
      {id: "channel:8", channel: "#remembered"},
    ],
  },
]

describe("active buffer preference", () => {
  test("restores only buffers present in the current bootstrap", () => {
    expect(selectPreferredBuffer(connections, "channel:8")).toEqual({
      activeChannelId: "channel:8",
      activeServerId: "server:42",
      view: "chat",
    })
    expect(selectPreferredBuffer(connections, "server:42")).toEqual({
      activeChannelId: null,
      activeServerId: "server:42",
      view: "server",
    })
    expect(selectPreferredBuffer(connections, "channel:missing")).toBeNull()
  })
})
