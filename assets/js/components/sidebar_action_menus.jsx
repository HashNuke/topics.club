import {offset, shift, useFloating} from "@floating-ui/react"
import React, {useState} from "react"

function ActionMenu({ariaLabel, buttonClass, items}) {
  const [open, setOpen] = useState(false)
  const {refs, floatingStyles} = useFloating({placement: "bottom-end", middleware: [offset(6), shift({padding: 8})]})

  function run(action) {
    action?.()
    setOpen(false)
  }

  return (
    <div className="relative">
      <button
        ref={refs.setReference}
        className={buttonClass}
        aria-label={ariaLabel}
        aria-expanded={open}
        onClick={(event) => {
          event.stopPropagation()
          setOpen((current) => !current)
        }}
        type="button"
      >
        <span className="hero-ellipsis-horizontal size-4" aria-hidden="true" />
      </button>
      {open && (
        <div ref={refs.setFloating} style={floatingStyles} role="menu" aria-label={`${ariaLabel} menu`} className="z-40 min-w-44 rounded-lg border border-slate-700 bg-[#121722] p-1 text-sm normal-case tracking-normal shadow-2xl shadow-black/40">
          {items.map((item) => (
            <button
              key={item.label}
              className={["w-full rounded-md px-3 py-2 text-left transition", item.danger ? "text-rose-200 hover:bg-rose-950/50" : "text-slate-200 hover:bg-slate-800"].join(" ")}
              onClick={() => run(item.action)}
              role="menuitem"
              type="button"
            >
              {item.label}
            </button>
          ))}
        </div>
      )}
    </div>
  )
}

export function ChannelActionMenu({channel, onCopyChannel, onLeaveChannel, onMarkRead}) {
  return (
    <ActionMenu
      ariaLabel={`Channel actions for ${channel.channel}`}
      buttonClass="grid size-7 place-items-center rounded-md text-slate-500 transition hover:bg-slate-700 hover:text-white"
      items={[
        {label: "Mark read", action: onMarkRead},
        {label: "Copy channel name", action: onCopyChannel},
        {label: "Leave channel", action: onLeaveChannel, danger: true},
      ]}
    />
  )
}

export function ServerActionMenu({server, onDisconnect, onEdit, onLeave, onReconnect}) {
  return (
    <ActionMenu
      ariaLabel={`Server actions for ${server.name}`}
      buttonClass="grid size-6 place-items-center rounded-md text-slate-500 transition hover:bg-slate-700 hover:text-white"
      items={[
        {label: "Connect or reconnect", action: onReconnect},
        {label: "Edit connection", action: onEdit},
        {label: "Disconnect", action: onDisconnect, danger: true},
        {label: "Leave server", action: onLeave, danger: true},
      ]}
    />
  )
}
