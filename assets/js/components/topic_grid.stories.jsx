import TopicGrid, {TopicCard} from "./topic_grid.tsx"

const topics = [
  {id: "elixir", channel: "#elixir", server_host: "irc.example.net", description: "Phoenix, OTP, and production Elixir help.", members: 426},
  {id: "phoenix", channel: "#phoenix", server_host: "irc.example.net", description: "LiveView patterns and framework support.", members: 188},
]

export default {title: "Discover/TopicGrid", component: TopicGrid, decorators: [(Story) => <div className="w-[48rem] max-w-full"><Story /></div>], args: {topics, onSelectTopic: () => {}}}
export const Suggestions = {}
export const Empty = {args: {topics: []}}
export const SingleCard = {render: () => <div className="w-80"><TopicCard topic={topics[0]} onSelectTopic={() => {}} /></div>}
export const MissingMetadata = {args: {topics: [{id: "quiet", channel: "#quiet", server_host: "irc.example.net", description: "A smaller conversation."}]}}
