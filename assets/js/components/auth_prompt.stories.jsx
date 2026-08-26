import AuthPrompt from "./auth_prompt.tsx"

export default {title: "Discover/AuthPrompt", component: AuthPrompt, parameters: {layout: "fullscreen"}, args: {developerOauth: false, topic: {id: "elixir", channel: "#elixir", server_host: "irc.example.net"}, onClose: () => {}}}
export const GoogleOnly = {}
export const WithDeveloperOAuth = {args: {developerOauth: true}}
export const LongTopicName = {args: {topic: {id: "long-topic", channel: "#a-very-long-community-topic", server_host: "irc.community.example"}}}
