import {autoUpdate, flip, FloatingPortal, offset, shift, useFloating} from "@floating-ui/react"
import React, {useEffect, useId, useRef, useState} from "react"
import type {Channel, ServerConnection} from "../types.ts"

interface ActionItem {
  label: string
  action?: () => void
  danger?: boolean
}

function ActionMenu({ariaLabel, buttonClass, items}: {ariaLabel: string; buttonClass: string; items: ActionItem[]}) {
  const [open, setOpen] = useState(false)
  const {refs, floatingStyles} = useFloating({
    placement: "right-start",
    middleware: [offset(6), flip(), shift({padding: 8})],
    whileElementsMounted: autoUpdate,
  })
  const menuId = useId()
  const triggerRef = useRef<HTMLButtonElement | null>(null)
  const menuRef = useRef<HTMLDivElement | null>(null)
  const itemRefs = useRef<Array<HTMLButtonElement | null>>([])
  const focusFirstItemRef = useRef(false)

  useEffect(() => {
    const closeForOtherMenu = (event: Event) => {
      if ((event as CustomEvent<string>).detail !== menuId) setOpen(false)
    }

    document.addEventListener("ircpipe:action-menu-open", closeForOtherMenu)
    return () => document.removeEventListener("ircpipe:action-menu-open", closeForOtherMenu)
  }, [menuId])

  useEffect(() => {
    if (!open) return

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

  function openMenu() {
    focusFirstItemRef.current = true
    document.dispatchEvent(new CustomEvent("ircpipe:action-menu-open", {detail: menuId}))
    setOpen(true)
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
      event.preventDefault()
      const destination = adjacentFocusable(triggerRef.current, event.shiftKey ? -1 : 1)
      setOpen(false)
      destination?.focus()
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
          if (open) setOpen(false)
          else openMenu()
        }}
        onKeyDown={(event) => {
          if (event.key !== "ArrowDown") return
          event.preventDefault()
          openMenu()
        }}
        type="button"
      >
        <span className="hero-ellipsis-horizontal size-4" aria-hidden="true" />
      </button>
      {open && (
        <FloatingPortal>
          <div
            id={menuId}
            ref={(element) => {
              menuRef.current = element
              refs.setFloating(element)
              if (element && focusFirstItemRef.current) {
                focusFirstItemRef.current = false
                queueMicrotask(() => itemRefs.current[0]?.focus())
              }
            }}
            style={floatingStyles}
            role="menu"
            aria-label={`${ariaLabel} menu`}
            className="z-[60] w-44 rounded-lg border border-slate-700 bg-[var(--app-panel)] p-1 text-sm normal-case tracking-normal shadow-2xl shadow-black/40"
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
        </FloatingPortal>
      )}
    </div>
  )
}

function adjacentFocusable(origin: HTMLElement | null, direction: -1 | 1): HTMLElement | null {
  if (!origin) return null

  const focusable = Array.from(document.querySelectorAll<HTMLElement>([
    "button:not([disabled])",
    "a[href]",
    "input:not([disabled])",
    "select:not([disabled])",
    "textarea:not([disabled])",
    "[tabindex]:not([tabindex='-1'])",
  ].join(","))).filter((element) => !element.closest("[role='menu']"))
  const originIndex = focusable.indexOf(origin)
  return originIndex < 0 ? null : focusable[originIndex + direction] || null
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
      buttonClass="grid size-7 place-items-center rounded-md text-slate-500 opacity-100 transition hover:bg-slate-700 hover:text-white lg:opacity-0 lg:focus:opacity-100 lg:group-hover:opacity-100"
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
