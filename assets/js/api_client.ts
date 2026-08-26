import type {BootstrapPayload} from "./bootstrap_state.ts"
import type {
  BackendConnection,
  BufferRecord,
  ChannelMembership,
  ChatMessage,
  EntityId,
  TopicInput,
} from "./types.ts"

interface ApiClientOptions {
  csrfToken?: string | null
  fetchImpl?: typeof globalThis.fetch
}

export interface ConnectionForm {
  name: string
  host: string
  port: number
  use_tls: boolean
  nickname: string
  sasl_password?: string
  server_password?: string
}

export interface BufferMessageParams {
  limit?: number
  before?: EntityId
  after?: EntityId
  commandIds?: string[]
}

const jsonHeaders = (csrfToken?: string | null): HeadersInit => ({
  "content-type": "application/json",
  ...(csrfToken ? {"x-csrf-token": csrfToken} : {}),
})

export function createApiClient({csrfToken, fetchImpl = globalThis.fetch}: ApiClientOptions = {}) {
  async function request<T>(path: string, options: RequestInit = {}): Promise<T> {
    const response = await fetchImpl(path, {
      credentials: "same-origin",
      headers: {
        ...jsonHeaders(csrfToken),
        ...(options.headers || {}),
      },
      ...options,
    })

    if (!response.ok) {
      throw new Error(await response.text())
    }

    return response.json() as Promise<T>
  }

  return {
    bootstrap: () => request<BootstrapPayload>("/api/bootstrap"),
    activity: () => request<Record<string, unknown>>("/api/activity", {method: "POST", body: JSON.stringify({})}),
    topics: () => request<{topics: TopicInput[]}>("/api/topics"),
    joinTopic: (topicId: EntityId) => request<{connection: BackendConnection; buffer: BufferRecord; topic?: TopicInput}>(`/api/topics/${topicId}/join`, {method: "POST", body: JSON.stringify({})}),
    createConnection: (connection: ConnectionForm) => request<{connection: BackendConnection}>("/api/connections", {method: "POST", body: JSON.stringify({connection})}),
    joinChannel: (connectionId: EntityId, channel: string) =>
      request<{channel: ChannelMembership}>(`/api/connections/${connectionId}/channels`, {method: "POST", body: JSON.stringify({channel})}),
    updateConnection: (connectionId: EntityId, connection: ConnectionForm) =>
      request<{connection: BackendConnection}>(`/api/connections/${connectionId}`, {method: "PUT", body: JSON.stringify({connection})}),
    deleteConnection: (connectionId: EntityId) => request<{deleted?: {server_connection_id: EntityId}}>(`/api/connections/${connectionId}`, {method: "DELETE", body: JSON.stringify({})}),
    bufferMessages: (bufferId: string, params: BufferMessageParams = {}) => {
      const search = new URLSearchParams()
      if (params.limit) search.set("limit", String(params.limit))
      if (params.before) search.set("before", String(params.before))
      if (params.after) search.set("after", String(params.after))
      if (params.commandIds?.length) search.set("command_ids", params.commandIds.join(","))
      search.set("buffer_id", bufferId)

      const query = search.toString()
      return request<{messages: ChatMessage[]}>(`/api/buffer_messages?${query}`)
    },
  }
}

export type ApiClient = ReturnType<typeof createApiClient>
