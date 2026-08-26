import LandingPage from "./landing_page.tsx"

const topics = [{id: "elixir", channel: "#elixir", server_host: "irc.example.net", description: "Phoenix, OTP, and production Elixir help.", members: 426}, {id: "phoenix", channel: "#phoenix", server_host: "irc.example.net", description: "LiveView patterns and framework support.", members: 188}]
export default {title: "Discover/LandingPage", component: LandingPage, parameters: {layout: "fullscreen"}, args: {currentUser: null, topics, developerOauth: false, selectedTopic: null, onSelectTopic: () => {}, onCloseAuth: () => {}}}
export const Guest = {}
export const DeveloperEnvironment = {args: {developerOauth: true}}
export const SignedIn = {args: {currentUser: {email: "mira@example.com"}, developerOauth: true}}
export const SignInPromptOpen = {args: {selectedTopic: topics[0], developerOauth: true}}
export const MobileWidth = {parameters: {viewport: {defaultViewport: "mobile1"}}}
