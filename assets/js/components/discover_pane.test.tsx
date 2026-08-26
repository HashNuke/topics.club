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

describe("DiscoverPane", () => {
  test("shows popular channels across networks in descending user order", () => {
    render(<DiscoverPane activeServer={activeServer} serverChannels={serverChannels} onJoinServerChannel={() => {}} onJoinThisServer={() => {}} />)

    const cards = screen.getAllByTestId("discover-channel")
    expect(cards.map((card) => card.textContent)).toEqual([
      expect.stringContaining("#largest"),
      expect.stringContaining("#medium"),
      expect.stringContaining("#small"),
    ])
    expect(screen.getByRole("tab", {name: "All IRC servers"})).toHaveAttribute("aria-selected", "true")
  })

  test("paginates the catalog in the browser", () => {
    render(<DiscoverPane activeServer={activeServer} serverChannels={serverChannels} pageSize={2} onJoinServerChannel={() => {}} onJoinThisServer={() => {}} />)

    expect(screen.getByText("Page 1 of 2")).toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", {name: "Next page"}))
    expect(screen.getByText("#small")).toBeInTheDocument()
    expect(screen.queryByText("#largest")).not.toBeInTheDocument()
  })

  test("joins a catalog channel from its card", () => {
    const onJoinServerChannel = vi.fn()
    render(<DiscoverPane activeServer={activeServer} serverChannels={serverChannels} onJoinServerChannel={onJoinServerChannel} onJoinThisServer={() => {}} />)

    fireEvent.click(screen.getByRole("button", {name: "Join #largest on OFTC"}))
    expect(onJoinServerChannel).toHaveBeenCalledWith(serverChannels[1])
  })

  test("joins a typed channel on the active server", () => {
    const onJoinThisServer = vi.fn()
    render(<DiscoverPane activeServer={activeServer} serverChannels={serverChannels} onJoinServerChannel={() => {}} onJoinThisServer={onJoinThisServer} />)

    fireEvent.click(screen.getByRole("tab", {name: "This server · Libera.Chat"}))
    fireEvent.change(screen.getByLabelText("Channel name"), {target: {value: "elixir"}})
    fireEvent.submit(screen.getByRole("form", {name: "Join a channel on Libera.Chat"}))

    expect(onJoinThisServer).toHaveBeenCalledWith("#elixir")
  })

  test("hides the current-server tab when there is no active server", () => {
    render(<DiscoverPane serverChannels={[]} onJoinServerChannel={() => {}} onJoinThisServer={() => {}} />)

    expect(screen.queryByRole("tab", {name: "This server"})).not.toBeInTheDocument()
    expect(screen.getByRole("tab", {name: "All IRC servers"})).toBeInTheDocument()
    expect(screen.queryByLabelText("Channel name")).not.toBeInTheDocument()
    expect(screen.getByText("Connect to an IRC server or wait for the directory refresh.")).toBeInTheDocument()
  })
})
