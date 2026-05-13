import React, {useEffect, useMemo, useState} from "react"
import {Socket} from "phoenix"

const csrfToken = document.querySelector("meta[name='csrf-token']")?.getAttribute("content")

async function api(path, options = {}) {
  const response = await fetch(path, {
    credentials: "same-origin",
    headers: {
      "content-type": "application/json",
      "x-csrf-token": csrfToken,
      ...(options.headers || {}),
    },
    ...options,
  })

  if (!response.ok) {
    throw new Error(await response.text())
  }

  return response.json()
}

export default function IrcpipeApp({currentUser}) {
  const [topics, setTopics] = useState([])
  const [connections, setConnections] = useState([])
  const [activeChannel, setActiveChannel] = useState(null)
  const [messages, setMessages] = useState([])
  const [draft, setDraft] = useState("")
  const [connectionForm, setConnectionForm] = useState({
    name: "",
    host: "",
    port: 6697,
    use_tls: true,
    nickname: currentUser?.email?.split("@")[0] || "ircpipe-user",
  })
  const [channelForm, setChannelForm] = useState({connection_id: "", channel: "#general"})
  const [retentionDays, setRetentionDays] = useState(currentUser?.message_retention_days || 3)
  const [error, setError] = useState(null)

  useEffect(() => {
    api("/api/topics").then(({topics}) => setTopics(topics)).catch(setError)
  }, [])

  useEffect(() => {
    if (!currentUser) return
    refreshConnections()
  }, [currentUser?.id])

  useEffect(() => {
    if (!currentUser) return

    const socket = new Socket("/socket")
    socket.connect()
    const channel = socket.channel(`user:${currentUser.id}`)

    channel.on("message", (message) => {
      setConnections((current) => incrementChannel(current, message))
      setMessages((current) => {
        if (activeChannel?.id !== message.channel_membership_id) return current
        return [...current, message]
      })
    })

    channel.on("mention", (message) => {
      if (document.visibilityState === "visible") return
      if (Notification.permission === "granted") {
        new Notification(`${message.nick || "IRC"} mentioned you in ${message.channel}`, {
          body: message.body,
        })
      }
    })

    channel.join()

    return () => socket.disconnect()
  }, [currentUser?.id, activeChannel?.id])

  const flatChannels = useMemo(
    () => connections.flatMap((connection) => connection.channels.map((channel) => ({...channel, connection}))),
    [connections]
  )

  async function refreshConnections() {
    const {connections} = await api("/api/connections")
    setConnections(connections)
    if (!channelForm.connection_id && connections[0]) {
      setChannelForm((form) => ({...form, connection_id: connections[0].id}))
    }
  }

  async function connectTopic(topic) {
    if (!currentUser) {
      window.location.href = "/users/register"
      return
    }

    const {connection} = await api("/api/connections", {
      method: "POST",
      body: JSON.stringify({
        connection: {
          name: topic.name,
          host: topic.server_host,
          port: topic.server_port,
          use_tls: topic.use_tls,
          nickname: connectionForm.nickname,
        },
      }),
    })

    const {channel} = await api(`/api/connections/${connection.id}/channels`, {
      method: "POST",
      body: JSON.stringify({channel: topic.channel}),
    })

    await refreshConnections()
    openChannel(channel)
  }

  async function saveConnection(event) {
    event.preventDefault()
    await api("/api/connections", {
      method: "POST",
      body: JSON.stringify({connection: connectionForm}),
    })
    setConnectionForm({...connectionForm, name: "", host: ""})
    await refreshConnections()
  }

  async function joinChannel(event) {
    event.preventDefault()
    const {channel} = await api(`/api/connections/${channelForm.connection_id}/channels`, {
      method: "POST",
      body: JSON.stringify({channel: channelForm.channel}),
    })
    await refreshConnections()
    openChannel(channel)
  }

  async function openChannel(channel) {
    setActiveChannel(channel)
    const {messages} = await api(`/api/channels/${channel.id}/messages`)
    setMessages(messages)
    await api(`/api/channels/${channel.id}/read`, {method: "POST", body: "{}"})
  }

  async function sendMessage(event) {
    event.preventDefault()
    if (!draft.trim() || !activeChannel) return

    await api(`/api/channels/${activeChannel.id}/messages`, {
      method: "POST",
      body: JSON.stringify({body: draft}),
    })
    setDraft("")
  }

  async function requestNotifications() {
    if ("Notification" in window) await Notification.requestPermission()
  }

  async function saveRetention(days) {
    setRetentionDays(days)
    await api("/api/settings", {
      method: "PUT",
      body: JSON.stringify({message_retention_days: days}),
    })
  }

  if (!currentUser) {
    return (
      <main className="min-h-screen bg-stone-50 text-zinc-950">
        <section className="mx-auto grid min-h-screen max-w-7xl content-center gap-10 px-5 py-10 lg:grid-cols-[0.9fr_1.1fr]">
          <div className="self-center">
            <p className="text-sm font-semibold uppercase tracking-wide text-emerald-700">IRC for the web</p>
            <h1 className="mt-4 text-5xl font-semibold leading-tight">Ircpipe</h1>
            <p className="mt-5 max-w-xl text-lg leading-8 text-zinc-600">
              Sign in, pick a topic, or connect to any IRC network you already use. Ircpipe keeps short scrollback
              so channels are useful even when your browser was closed.
            </p>
            <div className="mt-8 flex flex-wrap gap-3">
              <a className="rounded-md bg-zinc-950 px-4 py-2.5 text-sm font-semibold text-white" href="/users/register">
                Create account
              </a>
              <a className="rounded-md border border-zinc-300 px-4 py-2.5 text-sm font-semibold" href="/users/log-in">
                Log in
              </a>
            </div>
          </div>
          <TopicGrid topics={topics} onConnect={connectTopic} />
        </section>
      </main>
    )
  }

  return (
    <main className="grid min-h-screen grid-cols-[280px_1fr_340px] bg-zinc-950 text-zinc-100">
        <aside className="border-r border-zinc-800 bg-zinc-900 p-4">
        <div className="flex items-center justify-between">
          <a href="/" className="text-lg font-semibold">Ircpipe</a>
          <a className="text-sm text-zinc-400 hover:text-white" href="/users/settings">Account</a>
        </div>
        <button
          className="mt-4 w-full rounded-md border border-zinc-700 px-3 py-2 text-left text-sm text-zinc-200 hover:border-emerald-500"
          onClick={requestNotifications}
        >
          Enable browser notifications
        </button>
        <div className="mt-6 space-y-5">
          {connections.map((connection) => (
            <section key={connection.id}>
              <div className="flex items-center justify-between text-xs uppercase tracking-wide text-zinc-500">
                <span>{connection.name}</span>
                <span>{connection.status}</span>
              </div>
              <div className="mt-2 space-y-1">
                {connection.channels.map((channel) => (
                  <button
                    key={channel.id}
                    className={`flex w-full items-center justify-between rounded-md px-2 py-2 text-left text-sm ${
                    activeChannel?.id === channel.id ? "bg-emerald-500 text-zinc-950" : "hover:bg-zinc-800"
                    }`}
                    onClick={() => openChannel(channel)}
                  >
                    <span>{channel.channel}</span>
                    {channel.mention_count > 0 && (
                      <span className="rounded-full bg-amber-300 px-2 py-0.5 text-xs font-semibold text-zinc-950">
                        {channel.mention_count}
                      </span>
                    )}
                  </button>
                ))}
              </div>
            </section>
          ))}
        </div>
      </aside>

      <section className="flex min-w-0 flex-col">
        <header className="border-b border-zinc-800 px-5 py-4">
          <h2 className="text-xl font-semibold">{activeChannel?.channel || "Choose or join a channel"}</h2>
          <p className="text-sm text-zinc-500">Scrollback is retained for {retentionDays} day{retentionDays === 1 ? "" : "s"}.</p>
        </header>
        <div className="flex-1 overflow-y-auto px-5 py-4">
          {messages.map((message) => (
            <div key={message.id} className={`grid grid-cols-[9rem_1fr] gap-3 py-1 text-sm ${message.mentioned ? "text-amber-200" : ""}`}>
              <span className="truncate text-right font-medium text-zinc-500">{message.nick}</span>
              <span className="min-w-0 break-words">{message.body}</span>
            </div>
          ))}
        </div>
        <form className="border-t border-zinc-800 p-4" onSubmit={sendMessage}>
          <input
            className="w-full rounded-md border border-zinc-700 bg-zinc-900 px-3 py-3 text-sm outline-none focus:border-emerald-500"
            disabled={!activeChannel}
            value={draft}
            onChange={(event) => setDraft(event.target.value)}
            placeholder={activeChannel ? `Message ${activeChannel.channel}` : "Select a channel first"}
          />
        </form>
      </section>

      <aside className="space-y-6 border-l border-zinc-800 bg-zinc-900 p-4">
        {error && <div className="rounded-md border border-red-500/60 bg-red-950 p-3 text-sm">{String(error.message || error)}</div>}
        <section>
          <h3 className="text-sm font-semibold uppercase tracking-wide text-zinc-500">Suggested topics</h3>
          <TopicGrid topics={topics} onConnect={connectTopic} compact />
        </section>
        <section>
          <h3 className="text-sm font-semibold uppercase tracking-wide text-zinc-500">Connection</h3>
          <form className="mt-3 space-y-2" onSubmit={saveConnection}>
            <TextInput placeholder="Name" value={connectionForm.name} onChange={(name) => setConnectionForm({...connectionForm, name})} />
            <TextInput placeholder="irc.libera.chat" value={connectionForm.host} onChange={(host) => setConnectionForm({...connectionForm, host})} />
            <TextInput placeholder="Nickname" value={connectionForm.nickname} onChange={(nickname) => setConnectionForm({...connectionForm, nickname})} />
            <button className="w-full rounded-md bg-emerald-500 px-3 py-2 text-sm font-semibold text-zinc-950">Connect server</button>
          </form>
        </section>
        <section>
          <h3 className="text-sm font-semibold uppercase tracking-wide text-zinc-500">Join channel</h3>
          <form className="mt-3 space-y-2" onSubmit={joinChannel}>
            <select
              className="w-full rounded-md border border-zinc-700 bg-zinc-900 px-3 py-2 text-sm"
              value={channelForm.connection_id}
              onChange={(event) => setChannelForm({...channelForm, connection_id: event.target.value})}
            >
              <option value="">Choose server</option>
              {connections.map((connection) => <option key={connection.id} value={connection.id}>{connection.name}</option>)}
            </select>
            <TextInput placeholder="#channel" value={channelForm.channel} onChange={(channel) => setChannelForm({...channelForm, channel})} />
            <button className="w-full rounded-md border border-zinc-700 px-3 py-2 text-sm font-semibold hover:border-emerald-500">Join</button>
          </form>
        </section>
        <section>
          <h3 className="text-sm font-semibold uppercase tracking-wide text-zinc-500">Retention</h3>
          <div className="mt-3 grid grid-cols-3 gap-2">
            {[1, 2, 3].map((days) => (
              <button
                key={days}
                className={`rounded-md border px-3 py-2 text-sm ${retentionDays === days ? "border-emerald-500 bg-emerald-500 text-zinc-950" : "border-zinc-700"}`}
                onClick={() => saveRetention(days)}
              >
                {days}d
              </button>
            ))}
          </div>
        </section>
      </aside>
    </main>
  )
}

function TopicGrid({topics, onConnect, compact = false}) {
  return (
    <div className={compact ? "mt-3 space-y-2" : "grid gap-3 sm:grid-cols-2"}>
      {topics.map((topic) => (
        <button
          key={topic.id}
          className="rounded-lg border border-zinc-300 bg-white p-4 text-left text-zinc-950 shadow-sm transition hover:-translate-y-0.5 hover:border-emerald-500 hover:shadow-md"
          onClick={() => onConnect(topic)}
        >
          <div className="font-semibold">{topic.name}</div>
          <div className="mt-1 text-sm text-zinc-600">{topic.description}</div>
          <div className="mt-3 text-xs font-medium text-emerald-700">{topic.server_host} {topic.channel}</div>
        </button>
      ))}
    </div>
  )
}

function TextInput({value, onChange, placeholder}) {
  return (
    <input
      className="w-full rounded-md border border-zinc-700 bg-zinc-900 px-3 py-2 text-sm text-zinc-100 outline-none focus:border-emerald-500"
      placeholder={placeholder}
      value={value}
      onChange={(event) => onChange(event.target.value)}
    />
  )
}

function incrementChannel(connections, message) {
  return connections.map((connection) => ({
    ...connection,
    channels: connection.channels.map((channel) => {
      if (channel.id !== message.channel_membership_id) return channel
      return {
        ...channel,
        unread_count: (channel.unread_count || 0) + 1,
        mention_count: message.mentioned ? (channel.mention_count || 0) + 1 : channel.mention_count,
      }
    }),
  }))
}
