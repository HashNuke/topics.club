import React, {useEffect, useId, useLayoutEffect, useRef, useState} from "react"
import type {CommandCatalogEntry} from "../types.ts"

const MAX_COMPOSER_HEIGHT = 136

export interface ChatComposerProps {
  commandCatalog?: CommandCatalogEntry[]
  context?: "server" | "channel"
  disabled?: boolean
  draft: string
  error?: string | null
  inputId: string
  onSendMessage: React.FormEventHandler<HTMLFormElement>
  onUpdateDraft: (value: string) => void
  placeholder?: string
  statusLabel?: string | null
}

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
}: ChatComposerProps) {
  const suggestions = commandSuggestionsFor(draft, commandCatalog, context)
  const composerContainerRef = useRef<HTMLDivElement | null>(null)
  const textareaRef = useRef<HTMLTextAreaElement | null>(null)
  const optionRefs = useRef<Array<HTMLButtonElement | null>>([])
  const suggestionListId = useId()
  const [selectedSuggestion, setSelectedSuggestion] = useState(-1)
  const [suggestionMaxHeight, setSuggestionMaxHeight] = useState(0)
  const suggestionNames = suggestions.map((suggestion) => suggestion.name).join("\u0000")

  useEffect(() => setSelectedSuggestion(-1), [draft, suggestionNames])

  useEffect(() => {
    if (selectedSuggestion < 0) return
    const option = optionRefs.current[selectedSuggestion]
    if (typeof option?.scrollIntoView === "function") {
      option.scrollIntoView({block: "nearest"})
    }
  }, [selectedSuggestion])

  useLayoutEffect(() => {
    const textarea = textareaRef.current
    if (!textarea) return

    resizeComposerTextarea(textarea)
  }, [draft])

  useEffect(() => {
    const textarea = textareaRef.current
    if (!textarea) return

    let measuredWidth = textarea.getBoundingClientRect().width
    const resize = () => resizeComposerTextarea(textarea)
    const observer = typeof ResizeObserver === "undefined" ? null : new ResizeObserver((entries) => {
      const width = entries[0]?.contentRect.width
      if (width === undefined || width === measuredWidth) return

      measuredWidth = width
      resize()
    })

    observer?.observe(textarea)
    window.addEventListener("resize", resize)

    return () => {
      observer?.disconnect()
      window.removeEventListener("resize", resize)
    }
  }, [])

  useLayoutEffect(() => {
    const container = composerContainerRef.current
    if (!container || suggestions.length === 0) return

    const measureAvailableHeight = () => {
      const visibleViewportTop = window.visualViewport?.offsetTop ?? 0
      const availableHeight = Math.floor(container.getBoundingClientRect().top - visibleViewportTop - 20)
      setSuggestionMaxHeight(Math.min(480, Math.max(0, availableHeight)))
    }
    const observer = typeof ResizeObserver === "undefined" ? null : new ResizeObserver(measureAvailableHeight)

    measureAvailableHeight()
    observer?.observe(container)
    window.addEventListener("resize", measureAvailableHeight)
    window.addEventListener("scroll", measureAvailableHeight, true)
    window.visualViewport?.addEventListener("resize", measureAvailableHeight)
    window.visualViewport?.addEventListener("scroll", measureAvailableHeight)

    return () => {
      observer?.disconnect()
      window.removeEventListener("resize", measureAvailableHeight)
      window.removeEventListener("scroll", measureAvailableHeight, true)
      window.visualViewport?.removeEventListener("resize", measureAvailableHeight)
      window.visualViewport?.removeEventListener("scroll", measureAvailableHeight)
    }
  }, [draft, error, suggestions.length])

  function selectSuggestion(index: number): void {
    const command = suggestions[index]
    if (!command) return

    onUpdateDraft(`${command.name} `)
    requestAnimationFrame(() => textareaRef.current?.focus())
  }

  return (
    <form
      className="relative border-t border-slate-800/80 bg-[var(--app-sidebar)] px-3 pb-[calc(0.75rem+env(safe-area-inset-bottom))] pt-2 sm:p-4"
      onSubmit={onSendMessage}
    >
      {error && (
        <p id={`${inputId}-error`} className="mx-auto mb-2 max-w-4xl text-sm text-rose-300" role="alert">
          {error}
        </p>
      )}
      <div ref={composerContainerRef} className="relative mx-auto max-w-4xl">
        {suggestions.length > 0 && (
          <div
            role="listbox"
            id={suggestionListId}
            aria-label="Slash command suggestions"
            style={{maxHeight: suggestionMaxHeight}}
            className="absolute bottom-[calc(100%+0.5rem)] left-0 z-30 w-[min(28rem,calc(100vw-2rem))] overflow-y-auto rounded-lg border border-slate-700 bg-[var(--app-panel)] p-1 shadow-2xl shadow-black/40"
          >
            {suggestions.map((command, index) => (
              <button
                key={command.name}
                ref={(element) => {
                  optionRefs.current[index] = element
                }}
                id={`${suggestionListId}-option-${index}`}
                type="button"
                role="option"
                tabIndex={-1}
                aria-selected={selectedSuggestion === index}
                className={[
                  "grid w-full grid-cols-[4.5rem_1fr] gap-3 rounded-md px-3 py-2 text-left text-sm transition hover:bg-slate-800/80 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-cyan-300/70",
                  selectedSuggestion === index && "bg-slate-800/80",
                ].filter(Boolean).join(" ")}
                onMouseDown={(event) => {
                  event.preventDefault()
                }}
                onMouseEnter={() => setSelectedSuggestion(index)}
                onClick={() => selectSuggestion(index)}
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
        <div className="flex flex-col items-stretch gap-2 rounded-md border border-slate-700 bg-slate-950 p-2 transition focus-within:border-cyan-300 sm:flex-row sm:items-center sm:px-3">
          <div className="order-1 flex min-w-0 items-center justify-end gap-2 sm:order-2">
            {statusLabel && <ComposerStatus label={statusLabel} />}
            <button
              className="shrink-0 rounded-md bg-cyan-300 px-3 py-1.5 text-sm font-semibold text-cyan-950 transition hover:bg-white disabled:cursor-not-allowed disabled:bg-slate-700 disabled:text-white/70"
              disabled={disabled}
              type="submit"
            >
              Send
            </button>
          </div>
          <textarea
            ref={textareaRef}
            id={inputId}
            aria-label="Message composer"
            aria-describedby={error ? `${inputId}-error` : undefined}
            aria-autocomplete={suggestions.length > 0 ? "list" : undefined}
            aria-controls={suggestions.length > 0 ? suggestionListId : undefined}
            aria-haspopup={suggestions.length > 0 ? "listbox" : undefined}
            aria-activedescendant={selectedSuggestion >= 0 ? `${suggestionListId}-option-${selectedSuggestion}` : undefined}
            className="order-2 min-h-11 min-w-0 flex-1 resize-none bg-transparent px-1 py-2 text-base leading-6 text-slate-100 outline-none placeholder:text-slate-600 sm:order-1 sm:min-h-0 sm:py-2 sm:text-sm"
            value={draft}
            onChange={(event) => onUpdateDraft(event.target.value)}
            onFocus={() => requestAnimationFrame(scrollFocusedComposerIntoView)}
            onKeyDown={(event) => {
              if (event.nativeEvent.isComposing) return

              if (suggestions.length > 0 && event.key === "ArrowDown") {
                event.preventDefault()
                setSelectedSuggestion((current) => (current + 1) % suggestions.length)
                return
              }

              if (suggestions.length > 0 && event.key === "ArrowUp") {
                event.preventDefault()
                setSelectedSuggestion((current) => current <= 0 ? suggestions.length - 1 : current - 1)
                return
              }

              if (event.key !== "Enter") return

              if (event.metaKey || event.ctrlKey) {
                event.preventDefault()
                const start = event.currentTarget.selectionStart
                const end = event.currentTarget.selectionEnd
                onUpdateDraft(`${draft.slice(0, start)}\n${draft.slice(end)}`)
                requestAnimationFrame(() => textareaRef.current?.setSelectionRange(start + 1, start + 1))
                return
              }

              if (selectedSuggestion >= 0) {
                event.preventDefault()
                selectSuggestion(selectedSuggestion)
                return
              }

              event.preventDefault()
              if (disabled) return
              event.currentTarget.form?.requestSubmit()
            }}
            placeholder={placeholder}
            rows={1}
          />
        </div>
      </div>
    </form>
  )
}

function resizeComposerTextarea(textarea: HTMLTextAreaElement): void {
  textarea.style.height = "auto"
  textarea.style.height = `${Math.min(textarea.scrollHeight, MAX_COMPOSER_HEIGHT)}px`
  textarea.style.overflowY = textarea.scrollHeight > MAX_COMPOSER_HEIGHT ? "auto" : "hidden"
}

function ComposerStatus({label}: {label: string}) {
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

function commandSuggestionsFor(value: string, commandCatalog: CommandCatalogEntry[], context?: "server" | "channel"): CommandCatalogEntry[] {
  const trimmedStart = value.trimStart()
  if (!trimmedStart.startsWith("/") || trimmedStart.includes(" ")) return []

  const prefix = trimmedStart.slice(1).toLowerCase()
  return commandCatalog.filter(
    (command) =>
      (!context || command.contexts.includes(context)) &&
      command.name.slice(1).startsWith(prefix)
  )
}

function scrollFocusedComposerIntoView(): void {
  const active = document.activeElement
  if (!active?.matches?.("[aria-label='Message composer']")) return
  if (typeof active.scrollIntoView !== "function") return

  active.scrollIntoView({block: "nearest", inline: "nearest"})
}
