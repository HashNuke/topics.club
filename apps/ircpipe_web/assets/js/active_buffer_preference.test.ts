import {afterEach, describe, expect, test} from "vitest"
import {
  loadActiveBufferPreference,
  saveActiveBufferPreference,
  selectPreferredBuffer,
} from "./active_buffer_preference.ts"

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

afterEach(() => localStorage.clear())

describe("active buffer preference", () => {
  test("stores a user's selected buffer across page loads", () => {
    saveActiveBufferPreference(5, "channel:8")

    expect(loadActiveBufferPreference(5)).toBe("channel:8")
    expect(loadActiveBufferPreference(6)).toBeNull()
  })

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
