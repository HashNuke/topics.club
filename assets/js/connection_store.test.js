import {describe, expect, test} from "vitest"
import {
  channelFromBuffer,
  channelFromMembership,
  planServerRemoval,
  removeChannel,
  updateBufferRead,
  updateConnectionDetails,
  updateServerStatus,
  upsertJoinedChannel,
} from "./connection_store.js"

const server = {
  id: "server:1",
  server_connection_id: 1,
  name: "local",
  host: "127.0.0.1",
  nickname: "mira",
  status: "connected",
  channels: [{id: "channel:2", channel: "#elixir", topic: "on 127.0.0.1", unread_count: 2, mention_count: 1}],
}

describe("connection store", () => {
  test("builds and adds joined channels without duplicates", () => {
    const channel = channelFromMembership({id: 3, channel: "#phoenix"}, "127.0.0.1")
    const added = upsertJoinedChannel([server], {id: 1, status: "connected"}, channel, {updateStatus: true})

    expect(added[0].channels.map((item) => item.id)).toEqual(["channel:2", "channel:3"])
    expect(upsertJoinedChannel(added, {id: 1}, channel)[0].channels).toHaveLength(2)
    expect(channelFromBuffer({buffer_id: "channel:4", title: "#beam"}, {description: "BEAM"})).toMatchObject({
      id: "channel:4",
      channel: "#beam",
      topic: "BEAM",
    })
  })

  test("updates status and unread counters", () => {
    const status = updateServerStatus([server], {server_connection_id: 1, status: "errored", nickname: "mira_"})
    const read = updateBufferRead(status, {buffer_id: "channel:2", unread_count: 0, mention_count: 0})

    expect(read[0]).toMatchObject({status: "errored", nickname: "mira_"})
    expect(read[0].channels[0]).toMatchObject({unread_count: 0, mention_count: 0})
  })

  test("updates connection details and plans channel and server removal", () => {
    const updated = updateConnectionDetails([server], {
      id: 1,
      name: "local-new",
      host: "localhost",
      nickname: "mira",
      port: 6697,
      status: "connected",
      use_tls: true,
    })

    expect(updated[0]).toMatchObject({name: "local-new", host: "localhost", use_tls: true})
    expect(updated[0].channels[0].topic).toBe("on localhost")
    expect(removeChannel(updated, "channel:2")[0].channels).toEqual([])

    const plan = planServerRemoval([server, {...server, id: "server:5", server_connection_id: 5}], 1)
    expect([...plan.deletedChannelIds]).toEqual(["channel:2"])
    expect(plan.nextServer.id).toBe("server:5")
  })
})
