import {act, fireEvent, render, screen} from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import {useState} from "react"
import {afterEach, describe, expect, test, vi} from "vitest"
import type {CommandCatalogEntry} from "../types.ts"
import ChatComposer from "./chat_composer.tsx"

const defaultCommandCatalog: CommandCatalogEntry[] = [
  {name: "/join", usage: "/join #channel", description: "Join", required_permission: "user", contexts: ["server", "channel", "direct"], availability: "enabled", examples: []},
  {name: "/list", usage: "/list", description: "List", required_permission: "user", contexts: ["server", "channel", "direct"], availability: "enabled", examples: []},
]

class TestResizeObserver {
  static instances: TestResizeObserver[] = []
  readonly targets = new Set<Element>()

  constructor(private readonly callback: ResizeObserverCallback) {
    TestResizeObserver.instances.push(this)
  }

  observe = (target: Element) => this.targets.add(target)
  unobserve = (target: Element) => this.targets.delete(target)
  disconnect = () => this.targets.clear()

  trigger(target: Element, width = 0): void {
    this.callback([
      {target, contentRect: {width}} as unknown as ResizeObserverEntry,
    ], this as unknown as ResizeObserver)
  }
}

afterEach(() => {
  TestResizeObserver.instances = []
  vi.unstubAllGlobals()
})

function ComposerHarness({commandCatalog = defaultCommandCatalog, disabled = false, onStatusAction, onSubmit = vi.fn(), initialDraft = "", readOnly = false}: {commandCatalog?: CommandCatalogEntry[]; disabled?: boolean; onStatusAction?: () => void; onSubmit?: () => void; initialDraft?: string; readOnly?: boolean}) {
  const [draft, setDraft] = useState(initialDraft)

  return (
    <ChatComposer
      commandCatalog={commandCatalog}
      disabled={disabled}
      draft={draft}
      inputId="composer-test"
      onStatusAction={onStatusAction}
      onSendMessage={(event) => {
        event.preventDefault()
        onSubmit()
      }}
      onUpdateDraft={setDraft}
      readOnly={readOnly}
      statusActionLabel={onStatusAction ? "View issue" : undefined}
      statusLabel={onStatusAction ? "Connection needs attention." : undefined}
    />
  )
}

describe("ChatComposer", () => {
  test("sends with Enter and reserves Ctrl/Cmd+Enter for newlines", async () => {
    const user = userEvent.setup()
    const onSubmit = vi.fn()
    render(<ComposerHarness onSubmit={onSubmit} />)
    const composer = screen.getByLabelText("Message composer")

    await user.type(composer, "hello{Enter}")
    expect(onSubmit).toHaveBeenCalledOnce()

    fireEvent.keyDown(composer, {key: "Enter", ctrlKey: true})
    expect(composer).toHaveValue("hello\n")
    fireEvent.keyDown(composer, {key: "Enter", metaKey: true})
    expect(onSubmit).toHaveBeenCalledOnce()
    expect(composer).toHaveValue("hello\n\n")
  })

  test("grows with content and caps its height at five lines", () => {
    render(<ComposerHarness initialDraft="one" />)
    const composer = screen.getByLabelText("Message composer")
    Object.defineProperty(composer, "scrollHeight", {configurable: true, value: 240})

    fireEvent.change(composer, {target: {value: "one\ntwo\nthree\nfour\nfive\nsix"}})

    expect(composer).toHaveStyle({height: "136px", overflowY: "auto"})
  })

  test("recalculates its height when responsive width changes wrap the draft", () => {
    vi.stubGlobal("ResizeObserver", TestResizeObserver)
    render(<ComposerHarness initialDraft="a draft that wraps after resizing" />)
    const composer = screen.getByLabelText("Message composer")
    Object.defineProperty(composer, "scrollHeight", {configurable: true, value: 240})
    const observer = TestResizeObserver.instances.find((instance) => instance.targets.has(composer))

    act(() => observer?.trigger(composer, 220))

    expect(composer).toHaveStyle({height: "136px", overflowY: "auto"})
  })

  test("anchors filtered slash suggestions directly above the composer", async () => {
    const user = userEvent.setup()
    render(<ComposerHarness />)

    await user.type(screen.getByLabelText("Message composer"), "/j")
    const suggestions = screen.getByRole("listbox", {name: "Slash command suggestions"})

    expect(suggestions).toHaveClass("absolute")
    expect(suggestions).toHaveClass("overflow-y-auto")
    expect(suggestions.parentElement).toHaveClass("relative")
    expect(screen.getAllByRole("option")).toHaveLength(1)
  })

  test("remeasures suggestion height when the visual viewport pans", () => {
    vi.stubGlobal("ResizeObserver", TestResizeObserver)
    const visualViewport = new EventTarget() as VisualViewport
    Object.defineProperty(visualViewport, "offsetTop", {configurable: true, value: 40})
    vi.stubGlobal("visualViewport", visualViewport)
    render(<ComposerHarness initialDraft="/" />)
    const suggestions = screen.getByRole("listbox", {name: "Slash command suggestions"})
    const container = suggestions.parentElement as HTMLDivElement

    vi.spyOn(container, "getBoundingClientRect").mockReturnValue(domRectAt(180))
    act(() => visualViewport.dispatchEvent(new Event("scroll")))
    expect(suggestions).toHaveStyle({maxHeight: "120px"})

    Object.defineProperty(visualViewport, "offsetTop", {configurable: true, value: 70})
    act(() => visualViewport.dispatchEvent(new Event("scroll")))
    expect(suggestions).toHaveStyle({maxHeight: "90px"})
  })

  test("does not submit with Enter while sending is disabled", async () => {
    const user = userEvent.setup()
    const onSubmit = vi.fn()
    render(<ComposerHarness disabled onSubmit={onSubmit} />)

    await user.type(screen.getByLabelText("Message composer"), "hello{Enter}")

    expect(onSubmit).not.toHaveBeenCalled()
    expect(screen.getByLabelText("Message composer")).toHaveValue("hello")
  })

  test("preserves the draft and opens the issue while the IRC connection is unavailable", async () => {
    const user = userEvent.setup()
    const onStatusAction = vi.fn()
    render(<ComposerHarness disabled initialDraft="keep this draft" onStatusAction={onStatusAction} readOnly />)
    const composer = screen.getByLabelText("Message composer")

    await user.type(composer, " ignored")
    await user.click(screen.getByRole("button", {name: "View issue"}))

    expect(composer).toHaveValue("keep this draft")
    expect(composer).toHaveAttribute("readonly")
    expect(onStatusAction).toHaveBeenCalledOnce()
  })

  test("selects slash suggestions with arrow keys and Enter", async () => {
    const user = userEvent.setup()
    render(<ComposerHarness />)
    const composer = screen.getByLabelText("Message composer")

    await user.type(composer, "/")
    await user.keyboard("{ArrowDown}{ArrowDown}{Enter}")

    expect(composer).toHaveValue("/list ")
    expect(composer).toHaveFocus()
    expect(screen.queryByRole("listbox", {name: "Slash command suggestions"})).not.toBeInTheDocument()
  })

  test("keeps slash options out of the tab order and allows pointer selection", async () => {
    const user = userEvent.setup()
    render(<ComposerHarness />)

    await user.type(screen.getByLabelText("Message composer"), "/j")
    const option = screen.getByRole("option", {name: /\/join/i})
    expect(option).toHaveAttribute("tabindex", "-1")
    await user.click(option)

    expect(screen.getByLabelText("Message composer")).toHaveValue("/join ")
  })

  test("offers the full catalog without filtering commands by pane context", async () => {
    const user = userEvent.setup()
    const commandCatalog: CommandCatalogEntry[] = [
      ...defaultCommandCatalog,
      {name: "/msg", usage: "/msg nick message", description: "Message", required_permission: "user", contexts: ["server", "channel", "direct"], availability: "enabled", examples: []},
      {name: "/me", usage: "/me action", description: "Action", required_permission: "user", contexts: ["channel", "direct"], availability: "enabled", examples: []},
    ]
    render(<ComposerHarness commandCatalog={commandCatalog} />)

    await user.type(screen.getByLabelText("Message composer"), "/")

    expect(screen.getAllByRole("option").map((option) => option.textContent)).toEqual([
      expect.stringContaining("/join"),
      expect.stringContaining("/list"),
      expect.stringContaining("/msg"),
      expect.stringContaining("/me"),
    ])
  })

  test("scrolls later keyboard-selected suggestions into view", async () => {
    const user = userEvent.setup()
    const commandCatalog: CommandCatalogEntry[] = Array.from({length: 12}, (_, index) => ({
      name: `/command${index + 1}`,
      usage: `/command${index + 1}`,
      description: `Command ${index + 1}`,
      required_permission: "user",
      contexts: ["channel"],
      availability: "enabled",
      examples: [],
    }))
    render(<ComposerHarness commandCatalog={commandCatalog} />)
    const composer = screen.getByLabelText("Message composer")
    await user.type(composer, "/")
    const laterOption = screen.getByRole("option", {name: /\/command10/i})
    laterOption.scrollIntoView = vi.fn()

    for (let index = 0; index < 10; index += 1) await user.keyboard("{ArrowDown}")

    expect(laterOption).toHaveAttribute("aria-selected", "true")
    expect(laterOption.scrollIntoView).toHaveBeenCalledWith({block: "nearest"})
  })
})

function domRectAt(top: number): DOMRect {
  return {
    x: 0,
    y: top,
    top,
    right: 320,
    bottom: top + 48,
    left: 0,
    width: 320,
    height: 48,
    toJSON: () => ({}),
  }
}
