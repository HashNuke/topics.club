import React, {useState} from "react"
import type {ConnectionEditFocus} from "../connection_issue.ts"
import type {EditServerForm, ManualServerForm} from "../hooks/use_server_connections.ts"
import type {ServerConnection} from "../types.ts"

interface LabeledInputProps {
  autoComplete?: string
  autoFocus?: boolean
  id: string
  label: string
  onChange: (value: string) => void
  placeholder?: string
  type?: React.HTMLInputTypeAttribute
  value: string | number
}

export function LabeledInput({autoComplete, autoFocus, id, label, onChange, placeholder, type = "text", value}: LabeledInputProps) {
  return (
    <label className="block text-sm">
      <span className="mb-1 block text-xs font-semibold uppercase tracking-[0.14em] text-slate-500">{label}</span>
      <input
        id={id}
        autoFocus={autoFocus}
        className="w-full rounded-md border border-slate-800 bg-slate-950 px-3 py-2 text-slate-100 outline-none transition focus:border-cyan-300"
        autoComplete={autoComplete}
        placeholder={placeholder}
        type={type}
        value={value}
        onChange={(event) => onChange(event.target.value)}
      />
    </label>
  )
}

export function ManualJoinDialog({initialAdvancedOpen = false, onClose, onJoin}: {initialAdvancedOpen?: boolean; onClose: () => void; onJoin: (form: ManualServerForm) => void}) {
  const [advancedOpen, setAdvancedOpen] = useState(initialAdvancedOpen)
  const [form, setForm] = useState({
    host: "127.0.0.1",
    port: "6669",
    channels: "#elixir, #phoenix",
    nickname: "",
    saslPassword: "",
    serverPassword: "",
    useTls: false,
  })

  function submit(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault()
    onJoin(form)
  }

  return (
    <div className="fixed inset-0 z-50 grid place-items-center bg-black/70 px-4">
      <form aria-label="Join another server" className="w-full max-w-md rounded-lg border border-slate-700 bg-[var(--app-panel)] p-5 shadow-2xl" onSubmit={submit} role="dialog">
        <DialogHeader title="Join another server" description="Specify connection details to connect to a new server." onClose={onClose} />
        <div className="mt-5 space-y-3">
          <LabeledInput id="server-host" label="Server" value={form.host} onChange={(host) => setForm({...form, host})} />
          <div className="grid grid-cols-[1fr_auto] items-end gap-3">
            <LabeledInput id="server-port" label="Port" value={form.port} onChange={(port) => setForm({...form, port})} />
            <TlsToggle checked={form.useTls} onChange={(useTls) => setForm({...form, useTls})} />
          </div>
          <LabeledInput id="server-channels" label="Auto-join channels" value={form.channels} onChange={(channels) => setForm({...form, channels})} />
          <p className="text-xs leading-5 text-slate-500">Comma separated. These channels are joined after the server connects.</p>
          <details className="rounded-md border border-slate-800 bg-slate-950/50" open={advancedOpen} onToggle={(event) => setAdvancedOpen(event.currentTarget.open)}>
            <summary className="cursor-pointer select-none px-3 py-2.5 text-sm font-semibold text-slate-300 transition hover:text-white">Advanced connection options</summary>
            <div className="space-y-3 border-t border-slate-800 px-3 py-3">
              <LabeledInput id="server-nickname" label="Nickname (optional)" placeholder="Generated from your account if blank" value={form.nickname} onChange={(nickname) => setForm({...form, nickname})} />
              <LabeledInput autoComplete="new-password" id="sasl-password" label="Account password (SASL, optional)" type="password" value={form.saslPassword} onChange={(saslPassword) => setForm({...form, saslPassword})} />
              <p className="text-xs leading-5 text-slate-500">Authenticates your IRC account. Your nickname is used as the SASL account name.</p>
              <LabeledInput autoComplete="new-password" id="server-password" label="Server password (optional)" type="password" value={form.serverPassword} onChange={(serverPassword) => setForm({...form, serverPassword})} />
              <p className="text-xs leading-5 text-slate-500">Unlocks a password-protected network using IRC PASS. Keep TLS enabled when using passwords.</p>
            </div>
          </details>
        </div>
        <DialogActions confirmLabel="Join" onClose={onClose} />
      </form>
    </div>
  )
}

export function EditServerDialog({focus = "connection", onClose, onSave, reconnectOnSave = false, server}: {focus?: ConnectionEditFocus; onClose: () => void; onSave: (form: EditServerForm) => boolean | Promise<boolean>; reconnectOnSave?: boolean; server: ServerConnection}) {
  const [advancedOpen, setAdvancedOpen] = useState(focus === "credentials")
  const [saveError, setSaveError] = useState<string | null>(null)
  const [saving, setSaving] = useState(false)
  const [form, setForm] = useState({
    host: server.host || "",
    port: String(server.port || 6669),
    nickname: server.nickname || "",
    saslUsername: "",
    saslPassword: "",
    serverPassword: "",
    useTls: Boolean(server.use_tls || server.useTls),
  })

  async function submit(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault()
    setSaveError(null)
    setSaving(true)
    const saved = await onSave(form)
    setSaving(false)

    if (saved) onClose()
    else setSaveError(reconnectOnSave ? "The connection could not be saved and reconnected. Check the details and try again." : "The connection could not be updated. Check the details and try again.")
  }

  return (
    <div className="fixed inset-0 z-50 flex items-end bg-black/70 sm:grid sm:place-items-center sm:px-4">
      <form aria-label="Edit server" aria-modal="true" className="flex max-h-[calc(100dvh-1rem)] w-full max-w-md flex-col rounded-t-2xl border border-slate-700 bg-[var(--app-panel)] shadow-2xl sm:max-h-[calc(100dvh-2rem)] sm:rounded-xl" onSubmit={submit} role="dialog">
        <div className="shrink-0 p-5 pb-3">
          <DialogHeader title="Edit connection" description={reconnectOnSave ? "Fix the connection details, then reconnect." : "Update the server details used for this connection."} onClose={onClose} />
        </div>
        <div className="app-scrollbar min-h-0 flex-1 space-y-3 overflow-y-auto px-5 py-2">
          <LabeledInput autoFocus={focus === "connection"} id="edit-server-host" label="Server" value={form.host} onChange={(host) => setForm({...form, host})} />
          <div className="grid grid-cols-[1fr_auto] items-end gap-3">
            <LabeledInput id="edit-server-port" label="Port" value={form.port} onChange={(port) => setForm({...form, port})} />
            <TlsToggle checked={form.useTls} onChange={(useTls) => setForm({...form, useTls})} />
          </div>
          <LabeledInput autoFocus={focus === "nickname"} id="edit-server-nickname" label="Nickname" value={form.nickname} onChange={(nickname) => setForm({...form, nickname})} />
          <details className="rounded-lg border border-slate-800 bg-slate-950/50" open={advancedOpen} onToggle={(event) => setAdvancedOpen(event.currentTarget.open)}>
            <summary className="cursor-pointer select-none px-3 py-3 text-sm font-semibold text-slate-300 transition hover:text-white">Login credentials</summary>
            <div className="space-y-3 border-t border-slate-800 px-3 py-3">
              <LabeledInput autoFocus={focus === "credentials"} autoComplete="username" id="edit-sasl-username" label="IRC account name" placeholder="Leave blank to keep the current account" value={form.saslUsername} onChange={(saslUsername) => setForm({...form, saslUsername})} />
              <LabeledInput autoComplete="new-password" id="edit-sasl-password" label="IRC account password" placeholder="Leave blank to keep the current password" type="password" value={form.saslPassword} onChange={(saslPassword) => setForm({...form, saslPassword})} />
              <LabeledInput autoComplete="new-password" id="edit-server-password" label="Server password" placeholder="Leave blank to keep the current password" type="password" value={form.serverPassword} onChange={(serverPassword) => setForm({...form, serverPassword})} />
              <p className="text-xs leading-5 text-slate-500">Blank credential fields keep their currently saved values.</p>
            </div>
          </details>
          {saveError && <p id="edit-server-error" className="text-sm text-rose-300" role="alert">{saveError}</p>}
        </div>
        <div className="shrink-0 px-5 pb-[calc(1.25rem+env(safe-area-inset-bottom))] pt-3 sm:pb-5">
          <DialogActions confirmLabel={saving ? "Saving…" : reconnectOnSave ? "Save & reconnect" : "Save"} disabled={saving} onClose={onClose} />
        </div>
      </form>
    </div>
  )
}

export function LeaveServerDialog({onClose, onConfirm, server}: {onClose: () => void; onConfirm: () => void; server: ServerConnection}) {
  return (
    <div className="fixed inset-0 z-50 grid place-items-center bg-black/70 px-4">
      <section aria-label="Leave server" className="w-full max-w-sm rounded-lg border border-rose-900/70 bg-[var(--app-panel)] p-5 shadow-2xl" role="dialog">
        <DialogHeader title="Leave server" description={`Remove ${server.name} and its joined topics from this account.`} onClose={onClose} />
        <div className="mt-5 flex gap-3">
          <button type="button" className="flex-1 rounded-md border border-slate-700 px-4 py-2 text-sm font-semibold text-slate-300" onClick={onClose}>Cancel</button>
          <button className="flex-1 rounded-md bg-rose-300 px-4 py-2 text-sm font-semibold text-rose-950 hover:bg-white" onClick={onConfirm} type="button">Leave</button>
        </div>
      </section>
    </div>
  )
}

function DialogHeader({description, onClose, title}: {description: string; onClose: () => void; title: string}) {
  return (
    <div className="flex items-start justify-between gap-4">
      <div>
        <h2 className="text-lg font-semibold">{title}</h2>
        <p className="mt-1 text-sm leading-6 text-slate-500">{description}</p>
      </div>
      <button type="button" className="rounded-md px-2 py-1 text-slate-500 hover:bg-slate-800 hover:text-white" onClick={onClose} aria-label={`Close ${title.toLowerCase()}`}>
        <span className="hero-x-mark size-4" aria-hidden="true" />
      </button>
    </div>
  )
}

function TlsToggle({checked, onChange}: {checked: boolean; onChange: (checked: boolean) => void}) {
  return (
    <label className="flex h-[42px] items-center gap-2 rounded-md border border-slate-800 bg-slate-950 px-3 text-sm text-slate-300">
      <input type="checkbox" checked={checked} onChange={(event) => onChange(event.target.checked)} />
      <span>TLS</span>
    </label>
  )
}

function DialogActions({confirmLabel, disabled = false, onClose}: {confirmLabel: string; disabled?: boolean; onClose: () => void}) {
  return (
    <div className="mt-5 flex gap-3">
      <button type="button" className="flex-1 rounded-md border border-slate-700 px-4 py-2 text-sm font-semibold text-slate-300" onClick={onClose}>Cancel</button>
      <button className="flex-1 rounded-md bg-cyan-300 px-4 py-2 text-sm font-semibold text-cyan-950 transition hover:bg-white disabled:cursor-wait disabled:bg-slate-700 disabled:text-white/75" disabled={disabled}>{confirmLabel}</button>
    </div>
  )
}
