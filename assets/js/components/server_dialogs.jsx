import {useState} from "react"

export function LabeledInput({autoComplete, id, label, onChange, placeholder, type = "text", value}) {
  return (
    <label className="block text-sm">
      <span className="mb-1 block text-xs font-semibold uppercase tracking-[0.14em] text-slate-500">{label}</span>
      <input
        id={id}
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

export function ManualJoinDialog({initialAdvancedOpen = false, onClose, onJoin}) {
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

  function submit(event) {
    event.preventDefault()
    onJoin(form)
  }

  return (
    <div className="fixed inset-0 z-50 grid place-items-center bg-black/70 px-4">
      <form aria-label="Join another server" className="w-full max-w-md rounded-lg border border-slate-700 bg-[#101620] p-5 shadow-2xl" onSubmit={submit} role="dialog">
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

export function EditServerDialog({onClose, onSave, server}) {
  const [form, setForm] = useState({
    host: server.host || "",
    port: String(server.port || 6669),
    nickname: server.nickname || "",
    useTls: Boolean(server.use_tls || server.useTls),
  })

  function submit(event) {
    event.preventDefault()
    onSave(form)
  }

  return (
    <div className="fixed inset-0 z-50 grid place-items-center bg-black/70 px-4">
      <form aria-label="Edit server" className="w-full max-w-md rounded-lg border border-slate-700 bg-[#101620] p-5 shadow-2xl" onSubmit={submit} role="dialog">
        <DialogHeader title="Edit connection" description="Update the server details used for this connection." onClose={onClose} />
        <div className="mt-5 space-y-3">
          <LabeledInput id="edit-server-host" label="Server" value={form.host} onChange={(host) => setForm({...form, host})} />
          <div className="grid grid-cols-[1fr_auto] items-end gap-3">
            <LabeledInput id="edit-server-port" label="Port" value={form.port} onChange={(port) => setForm({...form, port})} />
            <TlsToggle checked={form.useTls} onChange={(useTls) => setForm({...form, useTls})} />
          </div>
          <LabeledInput id="edit-server-nickname" label="Nickname" value={form.nickname} onChange={(nickname) => setForm({...form, nickname})} />
        </div>
        <DialogActions confirmLabel="Save" onClose={onClose} />
      </form>
    </div>
  )
}

export function LeaveServerDialog({onClose, onConfirm, server}) {
  return (
    <div className="fixed inset-0 z-50 grid place-items-center bg-black/70 px-4">
      <section aria-label="Leave server" className="w-full max-w-sm rounded-lg border border-rose-900/70 bg-[#101620] p-5 shadow-2xl" role="dialog">
        <DialogHeader title="Leave server" description={`Remove ${server.name} and its joined topics from this account.`} onClose={onClose} />
        <div className="mt-5 flex gap-3">
          <button type="button" className="flex-1 rounded-md border border-slate-700 px-4 py-2 text-sm font-semibold text-slate-300" onClick={onClose}>Cancel</button>
          <button className="flex-1 rounded-md bg-rose-300 px-4 py-2 text-sm font-semibold text-rose-950 hover:bg-white" onClick={onConfirm} type="button">Leave</button>
        </div>
      </section>
    </div>
  )
}

function DialogHeader({description, onClose, title}) {
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

function TlsToggle({checked, onChange}) {
  return (
    <label className="flex h-[42px] items-center gap-2 rounded-md border border-slate-800 bg-slate-950 px-3 text-sm text-slate-300">
      <input type="checkbox" checked={checked} onChange={(event) => onChange(event.target.checked)} />
      <span>TLS</span>
    </label>
  )
}

function DialogActions({confirmLabel, onClose}) {
  return (
    <div className="mt-5 flex gap-3">
      <button type="button" className="flex-1 rounded-md border border-slate-700 px-4 py-2 text-sm font-semibold text-slate-300" onClick={onClose}>Cancel</button>
      <button className="flex-1 rounded-md bg-cyan-300 px-4 py-2 text-sm font-semibold text-cyan-950 hover:bg-white">{confirmLabel}</button>
    </div>
  )
}
