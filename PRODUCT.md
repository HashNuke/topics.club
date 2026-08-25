# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

## Users

The primary users are people looking for live, topic-based communities who should not need to understand IRC servers, networks, or setup before joining a conversation. The UI must remain beginner friendly throughout discovery and chat.

Experienced IRC users are a secondary audience. They retain escape hatches for connecting directly to arbitrary IRC servers and channels without making those concepts the default entry path.

## Product Purpose

`topics.club` makes open IRC communities approachable through topic-first discovery. It lets people browse interesting conversations, join one with a click, and continue in a full web IRC client with short-term continuity across sessions.

Success means a newcomer can move from an interesting topic to its active conversation without IRC configuration, while existing users can join additional communities across multiple networks without disrupting their current connections.

## Positioning

`topics.club` is a public, self-hostable web client whose curated discovery catalog maps friendly topics to real channels on open IRC networks, while server-scoped directories expose channels advertised by each connected network. Unlike a closed chat directory, joining a suggested topic creates or reuses a standards-compatible IRC connection, and power users can still explore or connect to networks and channels outside the curated catalog.

## Operating Context

- The landing page presents popular or interesting channels from multiple IRC servers as browsable topics, such as an anime community on one network or a mathematics channel on Libera.Chat.
- Curated cross-network discovery and server-scoped channel discovery are complementary experiences: the former helps beginners find interesting communities, while the latter lets users explore a specific connected IRC network.
- Selecting a topic while signed out preserves that intent through authentication, then opens the IRC client with the requested channel joined and active.
- Selecting a topic while already signed in opens the client directly, creates or reuses the requested server connection, adds that server to the connected-server list when necessary, joins the channel, and makes it active.
- Existing server connections and joined channels remain available when a new topic introduces another network.
- Each connected server has an in-app channel directory populated from that server's IRC `LIST` response. The directory is reachable either by entering `/list` for the server or by using an add-channel control beside the server name in the sidebar.
- Selecting a channel from a server directory joins it through the existing server connection, adds it beneath that server in the sidebar, and makes the channel active.
- Signed-in users can discover more topics inside the client or manually connect to arbitrary IRC servers and channels.
- Users chat through channel buffers, see connection and presence state, use IRC commands when needed, and receive mention indicators or browser notifications.

## Capabilities and Constraints

- The product uses a Phoenix backend with a React web client, same-origin JSON APIs, Phoenix Channels, PostgreSQL, and the `ircxd` IRC library.
- It preserves IRC protocol compatibility and supports multiple server connections per user, with one supervised runtime session per user/server pair.
- Google OAuth, email authentication, and a development-only local provider support sign-in. A requested topic must survive authentication.
- Messages are retained per user for a configurable one to three days; the product does not promise permanent history.
- Discovery data must carry enough server and channel metadata to complete a real join while presenting topics and conversations as the primary beginner-facing language.
- Server directories depend on IRC `LIST` data such as channel name, visible user count, and topic. They reflect only what the selected server advertises and must not be presented as a complete cross-network catalog.
- The active conversation and composer must remain usable on responsive/mobile web layouts.
- A future React Native client may reuse frontend concepts and business logic, but the current platform is web.

## Brand Commitments

- Preserve the name `topics.club`.
- Keep the product beginner friendly and topic first; do not require newcomers to learn IRC terminology before participating.
- Preserve IRC's openness and make the underlying server/channel relationship available when it is useful rather than hiding or removing it.
- The established direction is minimal, dark-mode friendly, responsive, and conversation focused.

## Evidence on Hand

- [docs/spec.md](docs/spec.md) defines the product goal, primary journey, discovery model, IRC runtime, and frontend requirements.
- [docs/implementation.md](docs/implementation.md) records implemented architecture and realtime interaction flows.
- [docs/design.html](docs/design.html) is an incumbent visual reference, not proof of user preference or product adoption.
- [README.md](README.md) documents implemented capabilities, authentication, retention, and self-hosting.
- Demo topics, member counts, and conversations in the source are fixtures and must not be presented as real popularity, activity, customers, or testimonials.
- No confirmed customer testimonials, usage benchmarks, press, or production adoption evidence is currently recorded.

## Product Principles

1. Lead with interesting conversations, using curated cross-network discovery for newcomers and protocol-native server directories for deeper exploration.
2. Make one-click discovery resolve into a real, active IRC connection with continuity across authentication.
3. Keep IRC open and interoperable, with advanced controls available as progressive disclosure.
4. Preserve a user's existing multi-server context when they explore something new.
5. Favor honest, short-lived continuity over pretending the product owns permanent community history.

## Accessibility & Inclusion

No formal accessibility conformance target has been confirmed. Beginner friendliness requires plain language, clear connection and error states, keyboard-usable controls, and responsive access to the active conversation and composer.
