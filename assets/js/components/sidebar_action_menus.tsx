import {offset, shift, useFloating} from "@floating-ui/react"
import React, {useEffect, useId, useRef, useState} from "react"
import type {Channel, ServerConnection} from "../types.ts"

interface ActionItem {
  label: string
  action?: () => void
  danger?: boolean
}

function ActionMenu({ariaLabel, buttonClass, items}: {ariaLabel: string; buttonClass: string; items: ActionItem[]}) {
  const [open, setOpen] = useState(false)
  const {refs, floatingStyles} = useFloating({placement: "bottom-end", middleware: [offset(6), shift({padding: 8})]})
  const menuId = useId()
  const triggerRef = useRef<HTMLButtonElement | null>(null)
  const menuRef = useRef<HTMLDivElement | null>(null)
  const itemRefs = useRef<Array<HTMLButtonElement | null>>([])

  useEffect(() => {
    if (!open) return

    itemRefs.current[0]?.focus()

    const closeOutside = (event: PointerEvent) => {
      const target = event.target as Node
      if (!menuRef.current?.contains(target) && !triggerRef.current?.contains(target)) setOpen(false)
    }

    document.addEventListener("pointerdown", closeOutside)
    return () => document.removeEventListener("pointerdown", closeOutside)
  }, [open])

  function run(action?: () => void) {
    action?.()
    setOpen(false)
    triggerRef.current?.focus()
  }

  function closeAndRestoreFocus() {
    setOpen(false)
    triggerRef.current?.focus()
  }

  function handleMenuKeyDown(event: React.KeyboardEvent<HTMLDivElement>) {
    const currentIndex = itemRefs.current.findIndex((item) => item === document.activeElement)

    if (event.key === "Escape") {
      event.preventDefault()
      closeAndRestoreFocus()
    } else if (event.key === "ArrowDown") {
      event.preventDefault()
      itemRefs.current[(currentIndex + 1) % items.length]?.focus()
    } else if (event.key === "ArrowUp") {
      event.preventDefault()
      itemRefs.current[(currentIndex - 1 + items.length) % items.length]?.focus()
    } else if (event.key === "Home") {
      event.preventDefault()
      itemRefs.current[0]?.focus()
    } else if (event.key === "End") {
      event.preventDefault()
      itemRefs.current[items.length - 1]?.focus()
    } else if (event.key === "Tab") {
      setOpen(false)
    }
  }

  return (
    <div className="relative">
      <button
        ref={(element) => {
          triggerRef.current = element
          refs.setReference(element)
        }}
        className={buttonClass}
        aria-label={ariaLabel}
        aria-expanded={open}
        aria-haspopup="menu"
        aria-controls={open ? menuId : undefined}
        onClick={(event) => {
          event.stopPropagation()
          setOpen((current) => !current)
        }}
        onKeyDown={(event) => {
          if (event.key !== "ArrowDown") return
          event.preventDefault()
          setOpen(true)
        }}
        type="button"
      >
        <span className="hero-ellipsis-horizontal size-4" aria-hidden="true" />
      </button>
      {open && (
        <div
          id={menuId}
          ref={(element) => {
            menuRef.current = element
            refs.setFloating(element)
          }}
          style={floatingStyles}
          role="menu"
          aria-label={`${ariaLabel} menu`}
          className="z-40 min-w-44 rounded-lg border border-slate-700 bg-[#121722] p-1 text-sm normal-case tracking-normal shadow-2xl shadow-black/40"
          onKeyDown={handleMenuKeyDown}
        >
          {items.map((item, index) => (
            <button
              key={item.label}
              ref={(element) => {
                itemRefs.current[index] = element
              }}
              className={["w-full rounded-md px-3 py-2 text-left transition", item.danger ? "text-rose-200 hover:bg-rose-950/50" : "text-white/90 hover:bg-slate-800"].join(" ")}
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

export function ChannelActionMenu({channel, onCopyChannel, onLeaveChannel, onMarkRead}: {channel: Channel; onCopyChannel: () => void; onLeaveChannel?: () => void; onMarkRead?: () => void}) {
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

export function DirectMessageActionMenu({channel, onClose}: {channel: Channel; onClose: () => void}) {
  return (
    <ActionMenu
      ariaLabel={`Private message actions for ${channel.channel}`}
      buttonClass="grid size-7 place-items-center rounded-md text-slate-500 opacity-0 transition hover:bg-slate-700 hover:text-white focus:opacity-100 group-hover:opacity-100"
      items={[{label: "Close", action: onClose, danger: true}]}
    />
  )
}

export function ServerActionMenu({server, onDisconnect, onEdit, onLeave, onReconnect}: {server: ServerConnection; onDisconnect?: () => void; onEdit: () => void; onLeave: () => void; onReconnect?: () => void}) {
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
