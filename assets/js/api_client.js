const jsonHeaders = (csrfToken) => ({
  "content-type": "application/json",
  ...(csrfToken ? {"x-csrf-token": csrfToken} : {}),
})

export function createApiClient({csrfToken, fetchImpl = globalThis.fetch} = {}) {
  async function request(path, options = {}) {
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

    return response.json()
  }

  return {
    bootstrap: () => request("/api/bootstrap"),
    topics: () => request("/api/topics"),
    joinTopic: (topicId) => request(`/api/topics/${topicId}/join`, {method: "POST", body: JSON.stringify({})}),
    updateConnection: (connectionId, connection) =>
      request(`/api/connections/${connectionId}`, {method: "PUT", body: JSON.stringify({connection})}),
    deleteConnection: (connectionId) => request(`/api/connections/${connectionId}`, {method: "DELETE", body: JSON.stringify({})}),
    bufferMessages: (bufferId, params = {}) => {
      const search = new URLSearchParams()
      if (params.limit) search.set("limit", String(params.limit))
      if (params.before) search.set("before", String(params.before))

      const query = search.toString()
      return request(`/api/buffers/${encodeURIComponent(bufferId)}/messages${query ? `?${query}` : ""}`)
    },
  }
}
