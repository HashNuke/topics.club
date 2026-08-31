import {describe, expect, test, vi} from "vitest"
import {createApiClient} from "./api_client.ts"

describe("api client", () => {
  test("loads bootstrap with same-origin credentials and csrf token", async () => {
    const fetchImpl = vi.fn().mockResolvedValue({ok: true, json: async () => ({ok: true})})
    const api = createApiClient({csrfToken: "csrf", fetchImpl})

    await expect(api.bootstrap()).resolves.toEqual({ok: true})

    expect(fetchImpl).toHaveBeenCalledWith(
      "/api/bootstrap",
      expect.objectContaining({
        credentials: "same-origin",
        headers: expect.objectContaining({"x-csrf-token": "csrf"}),
      })
    )
  })

  test("joins topics and fetches cursor-paginated buffer messages", async () => {
    const fetchImpl = vi.fn().mockResolvedValue({ok: true, json: async () => ({ok: true})})
    const api = createApiClient({fetchImpl})

    await api.joinTopic(42)
    await api.bufferMessages("channel:9", {before: 123, limit: 50})
    await api.bufferMessages("channel:9", {after: 456, limit: 25})
    await api.bufferMessages("channel:9", {commandIds: ["list-1", "who-2"]})

    expect(fetchImpl).toHaveBeenNthCalledWith(
      1,
      "/api/topics/42/join",
      expect.objectContaining({method: "POST", body: "{}"})
    )
    expect(fetchImpl).toHaveBeenNthCalledWith(
      2,
      "/api/buffer_messages?limit=50&before=123&buffer_id=channel%3A9",
      expect.objectContaining({credentials: "same-origin"})
    )
    expect(fetchImpl).toHaveBeenNthCalledWith(
      3,
      "/api/buffer_messages?limit=25&after=456&buffer_id=channel%3A9",
      expect.objectContaining({credentials: "same-origin"})
    )
    expect(fetchImpl).toHaveBeenNthCalledWith(
      4,
      "/api/buffer_messages?command_ids=list-1%2Cwho-2&buffer_id=channel%3A9",
      expect.objectContaining({credentials: "same-origin"})
    )
  })

  test("requests remote discovery pages, searches, and connection scope", async () => {
    const fetchImpl = vi.fn().mockResolvedValue({ok: true, json: async () => ({server_channels: []})})
    const api = createApiClient({fetchImpl})

    await api.discoveryServerChannels({connectionId: 42, page: 3, query: "beam tools"})
    await api.discoveryServerChannels({page: 1})

    expect(fetchImpl).toHaveBeenNthCalledWith(
      1,
      "/api/discovery/server_channels?connection_id=42&page=3&query=beam+tools",
      expect.objectContaining({credentials: "same-origin"})
    )
    expect(fetchImpl).toHaveBeenNthCalledWith(
      2,
      "/api/discovery/server_channels",
      expect.objectContaining({credentials: "same-origin"})
    )
  })

  test("updates a server connection", async () => {
    const fetchImpl = vi.fn().mockResolvedValue({ok: true, json: async () => ({connection: {id: 42}})})
    const api = createApiClient({csrfToken: "csrf", fetchImpl})

    await api.updateConnection(42, {name: "local", host: "127.0.0.1", port: 6697, use_tls: true, nickname: "mira"})

    expect(fetchImpl).toHaveBeenCalledWith(
      "/api/connections/42",
      expect.objectContaining({
        method: "PUT",
        body: JSON.stringify({
          connection: {name: "local", host: "127.0.0.1", port: 6697, use_tls: true, nickname: "mira"},
        }),
        headers: expect.objectContaining({"x-csrf-token": "csrf"}),
      })
    )
  })

  test("creates a server connection and joins a channel", async () => {
    const fetchImpl = vi.fn().mockResolvedValue({ok: true, json: async () => ({ok: true})})
    const api = createApiClient({csrfToken: "csrf", fetchImpl})

    await api.createConnection({name: "irc.example.net", host: "irc.example.net", port: 6697, use_tls: true, nickname: "mira"})
    await api.joinChannel(42, "##deep")

    expect(fetchImpl).toHaveBeenNthCalledWith(
      1,
      "/api/connections",
      expect.objectContaining({
        method: "POST",
        body: JSON.stringify({
          connection: {name: "irc.example.net", host: "irc.example.net", port: 6697, use_tls: true, nickname: "mira"},
        }),
        headers: expect.objectContaining({"x-csrf-token": "csrf"}),
      })
    )
    expect(fetchImpl).toHaveBeenNthCalledWith(
      2,
      "/api/connections/42/channels",
      expect.objectContaining({
        method: "POST",
        body: JSON.stringify({channel: "##deep"}),
        headers: expect.objectContaining({"x-csrf-token": "csrf"}),
      })
    )
  })

  test("deletes a server connection", async () => {
    const fetchImpl = vi.fn().mockResolvedValue({ok: true, json: async () => ({deleted: {server_connection_id: 42}})})
    const api = createApiClient({csrfToken: "csrf", fetchImpl})

    await api.deleteConnection(42)

    expect(fetchImpl).toHaveBeenCalledWith(
      "/api/connections/42",
      expect.objectContaining({
        method: "DELETE",
        body: "{}",
        headers: expect.objectContaining({"x-csrf-token": "csrf"}),
      })
    )
  })
})
