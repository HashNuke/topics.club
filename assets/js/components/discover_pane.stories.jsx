import DiscoverPane from "./discover_pane.jsx"

const topics = [{id: "elixir", channel: "#elixir", server_host: "irc.example.net", description: "Phoenix and OTP help.", members: 426}, {id: "phoenix", channel: "#phoenix", server_host: "irc.example.net", description: "LiveView patterns.", members: 188}]
export default {title: "Discover/DiscoverPane", component: DiscoverPane, decorators: [(Story) => <div className="flex h-[36rem] w-[64rem] max-w-full"><Story /></div>], args: {topics, onSelectTopic: () => {}}}
export const SuggestedTopics = {}
export const Empty = {args: {topics: []}}
export const MobileWidth = {decorators: [(Story) => <div className="flex h-[36rem] w-80"><Story /></div>]}
