import {describe, expect, test} from "vitest"
import {
  channelFromBuffer,
  channelFromMembership,
  directMessageFromBuffer,
  planServerRemoval,
  removeChannel,
  sortConversationBuffers,
  updateBufferRead,
  updateChannelUnread,
  updateConnectionDetails,
  updateServerStatus,
  upsertDirectMessage,
  upsertJoinedChannel,
} from "./connection_store.ts"

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

  test("applies authoritative unread counters only to channel buffers", () => {
    const unread = updateChannelUnread([server], "channel:2", 8, 3)
    const direct = updateChannelUnread(unread, "direct:9", 20, 10)

    expect(direct[0].channels[0]).toMatchObject({unread_count: 8, mention_count: 3})
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

  test("upserts and sorts direct messages before alphabetized channels", () => {
    const direct = directMessageFromBuffer({
      buffer_id: "direct:9",
      buffer_type: "direct_message",
      server_connection_id: 1,
      direct_message_thread_id: 9,
      title: "Akash",
      unread_count: 3,
      blocked: false,
    })
    const connection = {id: 1, name: "local", host: "127.0.0.1", status: "connected"}
    const added = upsertDirectMessage([server], connection, direct)
    const updated = upsertDirectMessage(added, connection, {...direct, channel: "akash_", unread_count: 4})

    expect(updated[0].channels.map((item) => item.id)).toEqual(["direct:9", "channel:2"])
    expect(updated[0].channels[0]).toMatchObject({channel: "akash_", unread_count: 4})

    const closed = upsertDirectMessage(updated, connection, {
      ...direct,
      closed_at: "2026-08-26T10:00:00Z",
    })
    expect(closed[0].channels.map((item) => item.id)).toEqual(["channel:2"])

    expect(sortConversationBuffers([
      {id: "channel:4", channel: "#Zulu", buffer_type: "channel"},
      {id: "direct:2", channel: "zed", buffer_type: "direct_message"},
      {id: "channel:3", channel: "#alpha", buffer_type: "channel"},
      {id: "direct:1", channel: "Akash", buffer_type: "direct_message"},
    ]).map((item) => item.id)).toEqual(["direct:1", "direct:2", "channel:3", "channel:4"])
  })

  test("does not let a direct-message snapshot overwrite canonical server status", () => {
    const direct = directMessageFromBuffer({
      buffer_id: "direct:9",
      buffer_type: "direct_message",
      server_connection_id: 1,
      direct_message_thread_id: 9,
      direct_message_revision: 1,
      title: "Akash",
      subtitle: "on 127.0.0.1",
      unread_count: 1,
      mention_count: 0,
      blocked: false,
      account: null,
      hostmask: null,
      closed_at: null,
    })

    const updated = upsertDirectMessage(
      [server],
      {id: 1, name: "local", host: "127.0.0.1", status: "connecting"},
      direct
    )

    expect(updated[0].status).toBe("connected")
  })
})
