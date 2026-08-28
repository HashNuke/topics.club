import type {Meta, StoryObj} from "@storybook/react-vite"
import DiscoveryChannelCard from "./discovery_channel_card.tsx"

const serverChannel = {
  id: 1,
  name: "#python",
  topic: "Python help, packaging, libraries, and the wider ecosystem.",
  user_count: 1284,
  network_id: 1,
  network_name: "Libera.Chat",
  server_host: "irc.libera.chat",
  server_port: 6697,
  use_tls: true,
}

const meta = {
  title: "Discover/DiscoveryChannelCard",
  component: DiscoveryChannelCard,
  decorators: [(Story) => <div className="w-80"><Story /></div>],
  args: {serverChannel, onJoin: () => {}},
} satisfies Meta<typeof DiscoveryChannelCard>

export default meta
type Story = StoryObj<typeof meta>

export const Default: Story = {}
export const Joining: Story = {args: {joining: true}}
export const ReadOnly: Story = {args: {onJoin: undefined}}
export const WithoutTopic: Story = {args: {serverChannel: {...serverChannel, topic: null}}}
