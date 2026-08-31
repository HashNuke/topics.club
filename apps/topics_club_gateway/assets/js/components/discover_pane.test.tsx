import {fireEvent, render, screen} from "@testing-library/react"
import {describe, expect, test, vi} from "vitest"
import DiscoverPane from "./discover_pane.tsx"
import type {ServerChannel, ServerConnection} from "../types.ts"

const activeServer: ServerConnection = {
  id: "server:42",
  server_connection_id: 42,
  name: "Libera.Chat",
  host: "irc.libera.chat",
  status: "connected",
  channels: [],
}

const serverChannels: ServerChannel[] = [
  {id: 1, name: "#small", topic: "A small room", user_count: 12, network_id: 1, network_name: "Libera.Chat", server_host: "irc.libera.chat", server_port: 6697, use_tls: true},
  {id: 2, name: "#largest", topic: "The largest room", user_count: 900, network_id: 2, network_name: "OFTC", server_host: "irc.oftc.net", server_port: 6697, use_tls: true},
  {id: 3, name: "#medium", topic: "A medium room", user_count: 120, network_id: 1, network_name: "Libera.Chat", server_host: "irc.libera.chat", server_port: 6697, use_tls: true},
]

function renderPane(overrides = {}) {
  const props = {
    activeServer,
    onJoinServerChannel: () => {},
    onJoinThisServer: () => {},
    onPageChange: () => {},
    onSearch: () => {},
    onSelectTab: () => {},
    page: 1,
    pageSize: 25,
    query: "",
    serverChannels,
    tab: "all" as const,
    totalChannels: serverChannels.length,
    totalPages: 1,
    ...overrides,
  }

  return render(<DiscoverPane {...props} />)
}

describe("DiscoverPane", () => {
  test("shows the remotely ordered channel page", () => {
    renderPane()

    const cards = screen.getAllByTestId("discover-channel")
    expect(cards.map((card) => card.textContent)).toEqual([
      expect.stringContaining("#small"),
      expect.stringContaining("#largest"),
      expect.stringContaining("#medium"),
    ])
    expect(screen.getByRole("tab", {name: "All IRC servers"})).toHaveAttribute("aria-selected", "true")
  })

  test("requests remote pages from pagination above and below the results", () => {
    const onPageChange = vi.fn()
    renderPane({onPageChange, page: 1, totalChannels: 53, totalPages: 3})

    expect(screen.getAllByText("Page 1 of 3")).toHaveLength(2)
    fireEvent.click(screen.getAllByRole("button", {name: "Next channel page"})[0])
    fireEvent.click(screen.getAllByRole("button", {name: "Next channel page"})[1])
    expect(onPageChange.mock.calls).toEqual([[2], [2]])
  })

  test("submits search to the remote directory", () => {
    const onSearch = vi.fn()
    renderPane({onSearch})

    fireEvent.change(screen.getByLabelText("Search public channels"), {target: {value: "  linux  "}})
    fireEvent.submit(screen.getByRole("search", {name: "Search discovered channels"}))

    expect(onSearch).toHaveBeenCalledWith("linux")
  })

  test("joins a catalog channel from its card", () => {
    const onJoinServerChannel = vi.fn()
    renderPane({onJoinServerChannel})

    fireEvent.click(screen.getByRole("button", {name: "Join #largest on OFTC"}))
    expect(onJoinServerChannel).toHaveBeenCalledWith(serverChannels[1])
  })

  test("joins a typed channel on the active server", () => {
    const onJoinThisServer = vi.fn()
    const onSelectTab = vi.fn()
    renderPane({onJoinThisServer, onSelectTab, tab: "server"})

    fireEvent.change(screen.getByLabelText("Channel name"), {target: {value: "elixir"}})
    fireEvent.submit(screen.getByRole("form", {name: "Join a channel on Libera.Chat"}))

    expect(onJoinThisServer).toHaveBeenCalledWith("#elixir")
  })

  test("hides the current-server tab when there is no active server", () => {
    renderPane({activeServer: undefined, serverChannels: [], totalChannels: 0})

    expect(screen.queryByRole("tab", {name: "This server"})).not.toBeInTheDocument()
    expect(screen.getByRole("tab", {name: "All IRC servers"})).toBeInTheDocument()
    expect(screen.queryByLabelText("Channel name")).not.toBeInTheDocument()
    expect(screen.getByText("Connect to an IRC server or wait for the directory refresh.")).toBeInTheDocument()
  })
})
