import LandingPage from "./landing_page.tsx"

const featuredChannels = [
  {id: 1, name: "#ruby", topic: "Ruby, Rails, gems, and the wider ecosystem.", user_count: 482, network_id: 1, network_name: "Libera.Chat", server_host: "irc.libera.chat", server_port: 6697, use_tls: true},
  {id: 2, name: "#python", topic: "Python help, packaging, libraries, and community projects.", user_count: 1284, network_id: 1, network_name: "Libera.Chat", server_host: "irc.libera.chat", server_port: 6697, use_tls: true},
  {id: 3, name: "#linux", topic: "Linux help, news, and daily driver talk.", user_count: 1842, network_id: 1, network_name: "Libera.Chat", server_host: "irc.libera.chat", server_port: 6697, use_tls: true},
  {id: 4, name: "#rust", topic: "The Rust language, tooling, and async ecosystem.", user_count: 697, network_id: 1, network_name: "Libera.Chat", server_host: "irc.libera.chat", server_port: 6697, use_tls: true},
  {id: 5, name: "#javascript", topic: "JavaScript across browsers, servers, and tooling.", user_count: 914, network_id: 1, network_name: "Libera.Chat", server_host: "irc.libera.chat", server_port: 6697, use_tls: true},
  {id: 6, name: "#ubuntu", topic: "Ubuntu support and community conversation.", user_count: 1127, network_id: 1, network_name: "Libera.Chat", server_host: "irc.libera.chat", server_port: 6697, use_tls: true},
]
export default {title: "App/LandingPage", component: LandingPage, parameters: {layout: "fullscreen"}, args: {currentUser: null, featuredChannels}}
export const Guest = {}
export const SignedIn = {args: {currentUser: {id: 1, email: "mira@example.com"}}}
export const Loading = {args: {featuredChannels: [], loading: true}}
export const Empty = {args: {featuredChannels: []}}
export const MobileWidth = {parameters: {viewport: {defaultViewport: "mobile1"}}}
