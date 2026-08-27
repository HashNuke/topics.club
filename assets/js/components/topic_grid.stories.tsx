import TopicGrid, {TopicCard} from "./topic_grid.tsx"

const topics = [
  {id: 1, channel: "#elixir", name: "#elixir", server_host: "irc.example.net", server_port: 6697, use_tls: true, description: "Phoenix, OTP, and production Elixir help.", members: 426},
  {id: 2, channel: "#phoenix", name: "#phoenix", server_host: "irc.example.net", server_port: 6697, use_tls: true, description: "LiveView patterns and framework support.", members: 188},
]

export default {title: "Discover/TopicGrid", component: TopicGrid, decorators: [(Story: React.ComponentType) => <div className="w-[48rem] max-w-full"><Story /></div>], args: {topics, onSelectTopic: () => {}}}
export const Suggestions = {}
export const Empty = {args: {topics: []}}
export const SingleCard = {render: () => <div className="w-80"><TopicCard topic={topics[0]} onSelectTopic={() => {}} /></div>}
export const LowActivity = {args: {topics: [{id: 3, channel: "#quiet", name: "#quiet", server_host: "irc.example.net", server_port: 6697, use_tls: true, description: "A smaller conversation.", members: 3}]}}
