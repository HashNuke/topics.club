import type {Meta, StoryObj} from "@storybook/react-vite"
import DiscoverPane from "./discover_pane.tsx"
import type {ServerChannel, ServerConnection} from "../types.ts"

const activeServer: ServerConnection = {id: "server:1", server_connection_id: 1, name: "Libera.Chat", host: "irc.libera.chat", status: "connected", mention_notifications_enabled: true, notification_preference_revision: 0, channels: []}
const serverChannels: ServerChannel[] = [
  {id: 1, name: "#linux", topic: "Linux help, news, and daily driver talk", user_count: 1842, network_id: 1, network_name: "Libera.Chat", server_host: "irc.libera.chat", server_port: 6697, use_tls: true, refreshed_at: "2026-08-26T02:00:00Z"},
  {id: 2, name: "#debian", topic: "Support for the universal operating system", user_count: 923, network_id: 2, network_name: "OFTC", server_host: "irc.oftc.net", server_port: 6697, use_tls: true, refreshed_at: "2026-08-26T01:30:00Z"},
  {id: 3, name: "#elixir", topic: "Elixir, OTP, Phoenix, and the BEAM", user_count: 426, network_id: 1, network_name: "Libera.Chat", server_host: "irc.libera.chat", server_port: 6697, use_tls: true, refreshed_at: "2026-08-26T02:00:00Z"},
  {id: 4, name: "#gentoo", topic: "Gentoo Linux users and developers", user_count: 318, network_id: 1, network_name: "Libera.Chat", server_host: "irc.libera.chat", server_port: 6697, use_tls: true, refreshed_at: "2026-08-26T02:00:00Z"},
]

const meta = {title: "Discover/DiscoverPane", component: DiscoverPane, parameters: {layout: "fullscreen"}, decorators: [(Story) => <div className="flex h-[46rem] bg-[#090b10]"><Story /></div>], args: {activeServer, serverChannels, onJoinServerChannel: () => {}, onJoinThisServer: () => {}}} satisfies Meta<typeof DiscoverPane>
export default meta
type Story = StoryObj<typeof meta>

export const AllServers: Story = {}
export const ThisServer: Story = {args: {initialTab: "server"}}
export const Loading: Story = {args: {serverChannels: [], loading: true}}
export const EmptyCatalog: Story = {args: {serverChannels: []}}
export const NoActiveServer: Story = {args: {activeServer: undefined, initialTab: "server"}}
export const Mobile: Story = {decorators: [(Story) => <div className="flex h-[46rem] w-[390px] bg-[#090b10]"><Story /></div>]}
