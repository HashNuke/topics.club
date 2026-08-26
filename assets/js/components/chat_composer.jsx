import {offset, shift, useFloating} from "@floating-ui/react"
import React from "react"

export default function ChatComposer({
  commandCatalog = [],
  context,
  disabled = false,
  draft,
  error,
  inputId,
  onSendMessage,
  onUpdateDraft,
  placeholder,
  statusLabel,
}) {
  const suggestions = commandSuggestionsFor(draft, commandCatalog, context)
  const {refs, floatingStyles} = useFloating({
    placement: "top-start",
    middleware: [offset(8), shift({padding: 12})],
  })

  return (
    <form
      className="relative border-t border-slate-800/80 bg-[#0f131b] px-3 pb-[calc(0.75rem+env(safe-area-inset-bottom))] pt-2 sm:p-4"
      onSubmit={onSendMessage}
    >
      {error && (
        <p id={`${inputId}-error`} className="mx-auto mb-2 max-w-4xl text-sm text-rose-300" role="alert">
          {error}
        </p>
      )}
      {suggestions.length > 0 && (
        <div
          ref={refs.setFloating}
          style={floatingStyles}
          role="listbox"
          aria-label="Slash command suggestions"
          className="z-30 w-[min(28rem,calc(100vw-2rem))] overflow-hidden rounded-lg border border-slate-700 bg-[#121722] p-1 shadow-2xl shadow-black/40"
        >
          {suggestions.map((command) => (
            <button
              key={command.name}
              type="button"
              role="option"
              aria-selected="false"
              className="grid w-full grid-cols-[4.5rem_1fr] gap-3 rounded-md px-3 py-2 text-left text-sm transition hover:bg-slate-800/80"
              onMouseDown={(event) => {
                event.preventDefault()
                onUpdateDraft(`${command.name} `)
              }}
            >
              <span className="font-semibold text-cyan-200">{command.name}</span>
              <span className="min-w-0">
                <span className="block truncate text-slate-300">{command.description}</span>
                <span className="block truncate text-xs text-slate-500">{command.usage}</span>
              </span>
            </button>
          ))}
        </div>
      )}
      <div
        ref={refs.setReference}
        className="mx-auto flex max-w-4xl flex-col items-stretch gap-2 rounded-md border border-slate-700 bg-slate-950 p-2 transition focus-within:border-cyan-300 sm:flex-row sm:items-center sm:px-3"
      >
        <div className="order-1 flex min-w-0 items-center justify-end gap-2 sm:order-2">
          {statusLabel && <ComposerStatus label={statusLabel} />}
          <button
            className="shrink-0 rounded-md bg-cyan-300 px-3 py-1.5 text-sm font-semibold text-cyan-950 transition hover:bg-white disabled:cursor-not-allowed disabled:bg-slate-700 disabled:text-white/70"
            disabled={disabled}
          >
            Send
          </button>
        </div>
        <textarea
          id={inputId}
          aria-label="Message composer"
          aria-describedby={error ? `${inputId}-error` : undefined}
          className="order-2 min-h-11 min-w-0 flex-1 resize-none bg-transparent px-1 py-2 text-base leading-6 text-slate-100 outline-none placeholder:text-slate-600 sm:order-1 sm:min-h-0 sm:py-2 sm:text-sm"
          value={draft}
          onChange={(event) => onUpdateDraft(event.target.value)}
          onFocus={() => requestAnimationFrame(scrollFocusedComposerIntoView)}
          placeholder={placeholder}
          rows={1}
        />
      </div>
    </form>
  )
}

function ComposerStatus({label}) {
  return (
    <div
      className="inline-flex min-w-0 max-w-[min(12rem,calc(100vw-8rem))] items-center gap-2 rounded-md border border-amber-300/30 bg-amber-300/10 px-2.5 py-1 text-xs font-medium text-amber-100 sm:max-w-56"
      role="status"
    >
      <span className="size-1.5 shrink-0 rounded-full bg-amber-300" />
      <span className="truncate">{label}</span>
    </div>
  )
}

function commandSuggestionsFor(value, commandCatalog, context) {
  const trimmedStart = value.trimStart()
  if (!trimmedStart.startsWith("/") || trimmedStart.includes(" ")) return []

  const prefix = trimmedStart.slice(1).toLowerCase()
  return commandCatalog.filter(
    (command) =>
      command.availability !== "disabled" &&
      (!context || command.contexts?.includes(context)) &&
      command.name.slice(1).startsWith(prefix)
  )
}

function scrollFocusedComposerIntoView() {
  const active = document.activeElement
  if (!active?.matches?.("[aria-label='Message composer']")) return
  if (typeof active.scrollIntoView !== "function") return

  active.scrollIntoView({block: "nearest", inline: "nearest"})
}
