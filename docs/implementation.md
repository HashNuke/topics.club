# topics.club implementation plan

## Research notes

- Phoenix Channels support browser and native clients over WebSocket or long polling, which fits the React web client now and a future mobile client later.
- Phoenix clients can join multiple channels over one socket connection. Use one frontend socket per browser session and multiplex app topics over it, rather than opening a WebSocket per IRC channel.
- Phoenix's JavaScript client exposes socket lifecycle callbacks such as open, close, and error; use those to drive connection health UI in React.
- Channel pushes support `ok`, `error`, and `timeout` replies; use those replies for send/join/leave feedback instead of making the UI infer success.
- Browser notification permission must be requested from a user gesture. Client-side notifications are enough for in-browser mention notifications while the app is open; backend web push is only needed later for notifications when the app is closed.

References:

- Phoenix Channels guide: https://hexdocs.pm/phoenix/channels.html
- Phoenix JavaScript client docs: https://hexdocs.pm/phoenix/js/
- Phoenix Socket class docs: https://hexdocs.pm/phoenix/js/classes/Socket.html
- MDN Notifications API guide: https://developer.mozilla.org/en-US/docs/Web/API/Notifications_API/Using_the_Notifications_API

## Architecture decision

- [x] Use one Phoenix `Socket` connection per signed-in browser session.
- [x] Join one high-level user channel: `user:{user_id}`.
- [x] Keep channel-specific IRC events inside payloads instead of joining one Phoenix topic per IRC channel.
- [x] Keep the one-IRC-session-per-`{user_id, server_connection_id}` backend invariant from `docs/spec.md`.
- [ ] Use REST `/api/*` for initial loads, history pagination, and durable mutations.
- [x] Use Phoenix Channel pushes and socket lifecycle callbacks for realtime events, command submissions, send-message acknowledgements, and connection health.

Rationale: the UI needs many IRC buffers, but the browser should not create a WebSocket per IRC channel. Phoenix already multiplexes channel topics over one socket, and this app can go further by using one authenticated user channel as the event bus for all of the user's server buffers, channel buffers, user lists, notices, and notifications.

## Data model checklist

- [ ] Add a first-class buffer concept in API payloads:
  - [x] `buffer_id`
  - [ ] `buffer_type`: `server`, `channel`, `service`, or `dm`
  - [x] `server_connection_id`
  - [x] `channel_membership_id` when applicable
  - [x] `title`
  - [x] `subtitle`
  - [x] `status`
- [x] Represent server buffers for server logs, MOTD, connection lifecycle, numeric replies, and service notices.
- [x] Represent channel buffers for IRC channel messages and channel-local system events.
- [ ] Represent service buffers or service-tagged messages for `NickServ`, `ChanServ`, and similar services.
- [ ] Store message `kind` values:
  - [ ] `message`
  - [ ] `action`
  - [ ] `notice`
  - [ ] `system`
  - [ ] `error`
  - [ ] `command`
- [ ] Store stable message ordering with `occurred_at` plus `id`.
- [ ] Store sender metadata:
  - [ ] `nick`
  - [ ] `hostmask` when available
  - [ ] role markers where applicable
- [ ] Store user list entries per channel:
  - [ ] `nick`
  - [ ] `role`: `owner`, `admin`, `op`, `halfop`, `voice`, or `user`
  - [ ] `status`: `online`, `away`, or unknown
  - [ ] last observed timestamp
- [ ] Store unread and mention counters per buffer, not only per channel.
- [ ] Keep message retention capped by the user's 1-3 day setting.

## Initial load flow

- [x] React loads `/chat`.
- [x] Server-rendered root passes `current_user`, CSRF token, and app mode.
- [x] React fetches `/api/bootstrap`.
- [x] `/api/bootstrap` returns:
  - [x] current user profile
  - [x] notification preference state
  - [x] server connections
  - [x] buffers ordered for the sidebar
  - [x] active or last-opened buffer
  - [x] recent messages for visible buffers
  - [x] current channel user lists
  - [x] suggested topics for Discover
- [x] React opens one Phoenix socket.
- [x] React joins `user:{user_id}`.
- [x] UserChannel join reply includes server time and optional missed event cursor.
- [ ] React reconciles any events newer than the bootstrap cursor.

## Realtime event contract

- [ ] Define all events as versioned payloads with `type`, `version`, `event_id`, and `occurred_at`.
- [ ] Push `buffer:message` for normal channel messages, notices, actions, and service replies.
- [ ] Push `buffer:system` for join, part, quit, nick change, topic changes, and server lifecycle lines.
- [ ] Push `buffer:read` when counters are reset.
- [ ] Push `buffer:joined` when a channel or server buffer is created.
- [x] Push `buffer:left` when the user leaves a channel.
- [ ] Push `buffer:error` for join failures, send failures, bans, invite-only failures, nickname errors, TLS failures, and backend IRC errors.
- [ ] Push `presence:sync` for full user list refreshes.
- [ ] Push `presence:diff` for joins, parts, quits, nick changes, role changes, and away state changes.
- [x] Push `server:status` for `connecting`, `connected`, `reconnecting`, `errored`, and `disconnected`.
- [ ] Push `notification:mention` for client-side browser notification decisions.

## Sending messages

- [x] React submits channel messages through the Phoenix user channel with `channel.push("message:send", payload)`.
- [ ] Payload includes:
  - [x] `client_message_id`
  - [x] `buffer_id`
  - [x] `body`
  - [ ] local draft metadata if needed
- [x] Backend validates buffer ownership through `current_scope.user`.
- [x] Backend routes channel messages to `Ircpipe.Irc.Session.say/3`.
- [x] Backend persists the user's outgoing message after IRC send acceptance.
- [x] Backend replies `ok` with canonical message payload.
- [x] Backend replies `error` with a typed reason if the buffer is unavailable.
- [ ] Backend replies `timeout` or lets the Phoenix client timeout surface a networking issue.
- [x] React shows pending outgoing messages with `client_message_id`.
- [x] React replaces pending messages with canonical messages on `ok`.
- [ ] React marks pending messages failed on `error` or `timeout`, with retry affordance.
  - [x] failed status
  - [ ] retry affordance

## Slash commands

- [x] React detects a leading `/` only to open a Floating UI command popover.
- [x] React never treats slash commands as authoritative client-only behavior.
- [x] React sends slash-command submissions to the backend as `command:run`.
- [x] Backend parses and validates slash commands.
- [x] Backend returns structured command results.
- [ ] Backend emits system messages for command outcomes that should remain in the buffer.
- [x] Add command suggestions endpoint or channel event:
  - [x] `/join`
  - [x] `/part`
  - [x] `/leave`
  - [x] `/msg`
  - [x] `/nick`
  - [x] `/me`
  - [x] `/topic`
  - [x] `/quote` for advanced/raw IRC commands, if allowed
- [ ] Backend returns completion metadata:
  - [x] command name
  - [x] usage
  - [x] description
  - [ ] required permission
  - [ ] examples
- [x] React uses Floating UI for the slash-command popover.
- [x] Tests cover command detection, completion display, backend parsing, and error feedback.

## Leaving channels and servers

- [ ] Add channel overflow menu in the UI.
- [ ] Add server overflow menu in the UI.
- [ ] Use Floating UI for both popover menus.
- [ ] Channel menu actions:
  - [ ] Mark read
  - [ ] Copy channel name
  - [ ] Leave channel
- [ ] Server menu actions:
  - [ ] Connect or reconnect
  - [ ] Disconnect
  - [ ] Edit connection
  - [ ] Leave server
- [ ] Backend channel leave flow:
  - [x] authorize membership
  - [x] send IRC `PART`
  - [x] mark channel membership as left or delete it
  - [x] broadcast `buffer:left`
- [ ] Backend server leave flow:
  - [x] authorize server connection
  - [x] send IRC `QUIT` or close session
  - [x] stop the session process
  - [ ] mark all buffers as left or archived
  - [ ] broadcast `server:status` and `buffer:left`
- [ ] UI confirms destructive server removal.

## Connection health and backend failure feedback

- [x] React tracks Phoenix socket state with `onOpen`, `onClose`, `onError`, and `connectionState()`.
- [x] Show a small top-bar connection status indicator:
  - [x] connected
  - [x] reconnecting
  - [x] offline
  - [x] degraded
- [x] Disable message send while the Phoenix socket is disconnected.
- [x] Queue drafts locally but do not pretend they were sent.
- [x] Surface channel push timeouts as "Still trying" or "Send failed".
- [ ] Show server-specific IRC connection failures in the server buffer.
- [ ] Push backend IRC session failures as `server:status` and `buffer:error`.
- [ ] Add retry actions for:
  - [ ] reconnect backend socket
  - [ ] reconnect IRC server
  - [ ] retry failed message
- [ ] Add tests for socket close, channel timeout, and IRC session error states.
  - [x] realtime join error shows degraded status
  - [x] channel send error shows failed status

## User list flow

- [ ] Backend parses IRC names replies and membership changes through `ircxd`.
  - [x] names replies
  - [x] membership changes
- [x] Backend normalizes roles into a stable role enum.
- [x] UserChannel pushes `presence:sync` after join and reconnect.
- [x] UserChannel pushes `presence:diff` for incremental changes.
- [x] React stores user lists per channel buffer.
- [x] React groups users by role and status.
- [x] React caps each group visually and allows expansion.
- [x] React hides user sidebar for non-channel views such as Discover and server buffers.
- [x] Server buffers do not show channel user lists.

## Message history and rendering limits

- [x] Initial message fetch returns latest 150 messages for the active buffer.
- [ ] Fetch older history in pages of 50 when scrolling near the top.
- [x] Keep a soft client-side render cap of 300-500 messages per open buffer.
- [x] Do not trim rendered messages while the user is scrolled up reading older history.
- [ ] If the user is near the bottom:
  - [ ] append incoming messages
  - [ ] auto-scroll
  - [ ] trim oldest messages over the cap
- [ ] If the user is not near the bottom:
  - [ ] append incoming messages
  - [ ] keep scroll position stable
  - [ ] show `N new messages`
  - [ ] defer trimming until the user returns to the bottom
- [x] Use cursor pagination:
  - [x] `GET /api/buffers/:id/messages?limit=150`
  - [x] `GET /api/buffers/:id/messages?before=<message_cursor>&limit=50`
- [ ] Preserve scroll offset when prepending older messages.

## Notifications

- [x] Keep the current spec behavior for the first implementation: client-side browser notifications for mentions while the document is hidden.
- [x] Backend persists mention notifications for unread state and notification history.
- [x] Backend pushes `notification:mention` over `user:{user_id}`.
- [x] React checks:
  - [x] document visibility
  - [x] user notification preference
  - [x] browser notification permission
  - [x] whether the message came from the current user
- [x] React shows a browser notification only when appropriate.
- [x] Request browser permission only after clicking the bell.
- [ ] Do not implement backend Web Push in the first pass.
- [ ] Add backend Web Push later only if we need notifications while the web app is closed or no socket is connected.

## API checklist

- [x] `GET /api/bootstrap`
- [x] `GET /api/topics`
- [x] `POST /api/topics/:id/join`
- [x] `GET /api/buffers/:id/messages`
- [x] `POST /api/channels/:id/read`
- [x] `POST /api/connections`
- [ ] `PUT /api/connections/:id`
- [x] `POST /api/connections/:id/connect`
- [x] `POST /api/connections/:id/disconnect`
- [ ] `DELETE /api/connections/:id`
- [x] `POST /api/channel_memberships/:id/leave`
- [x] `PUT /api/settings`
- [x] Keep all authenticated endpoints under pipelines that assign `current_scope`.
- [x] Pass `current_scope` or `current_scope.user` into context functions for user-scoped data.

## Phoenix channel checklist

- [x] Keep `IrcpipeWeb.UserSocket` authenticated by session cookie.
- [x] Keep `IrcpipeWeb.UserChannel` as the single realtime bus.
- [ ] Add `handle_in/3` handlers:
  - [x] `message:send`
  - [x] `command:run`
  - [x] `buffer:read`
  - [x] `channel:leave`
  - [x] `server:disconnect`
  - [x] `server:reconnect`
- [ ] Add typed reply payloads for every handler:
  - [ ] `ok`
  - [ ] `error`
  - [ ] `timeout`
- [ ] Add event serialization helpers so REST and realtime payloads match.
- [ ] Add channel tests for authorization, replies, broadcasts, and failure payloads.
  - [x] `message:send` ownership, reply, IRC send, and persistence
  - [x] `command:run` reply
  - [x] `buffer:read` counter reset reply
  - [x] `channel:leave` ownership, reply, IRC part, and deletion
  - [x] `server:disconnect` and `server:reconnect` ownership and replies
  - [x] `server:status` scoped broadcast

## IRC runtime checklist

- [x] Replace or adapt `Ircpipe.Irc.Session` to use `~/projects/ircxd`.
- [x] Keep sessions supervised by `Ircpipe.Irc.SessionSupervisor`.
- [x] Keep sessions registered by `{user_id, server_connection_id}`.
- [ ] Emit server-buffer messages for:
  - [ ] connect start
  - [ ] connect success
  - [ ] connect failure
  - [ ] disconnect
  - [ ] reconnect
  - [ ] MOTD
  - [ ] numeric replies
  - [ ] service notices
- [ ] Emit channel-buffer messages for:
  - [ ] `PRIVMSG`
  - [ ] `NOTICE`
  - [ ] `/me` actions
  - [ ] joins
  - [ ] parts
  - [ ] quits
  - [ ] nick changes
  - [ ] topic changes
- [x] Track channel user lists from IRC names and membership events.
  - [x] IRC names replies
  - [x] membership events
- [ ] Handle reconnect by rejoining persisted channels.
- [ ] Broadcast normalized events through `Ircpipe.Chat` or a dedicated realtime boundary.

## React state checklist

- [x] Create an API client module for bootstrap/history/mutations.
- [x] Create a Phoenix socket client module.
- [ ] Create a reducer/store for:
  - [x] connections
  - [x] buffers
  - [x] active buffer
  - [x] messages by buffer
  - [x] users by channel buffer
  - [x] unread counters
  - [x] connection health
  - [x] notification state
- [ ] Keep React components UI-focused.
- [ ] Keep transport/event normalization out of components.
- [x] Add tests for reducers and event application.
- [ ] Add React component tests for:
  - [ ] leaving channel/server menus
  - [ ] slash command popover
  - [ ] backend connection failure banner
  - [ ] send failure and retry
  - [ ] `N new messages` behavior

## Testing checklist

- [ ] Backend context tests for buffer ownership and scoping.
- [x] Backend channel tests for `UserChannel`.
- [ ] Backend API tests for bootstrap, history, join, leave, and settings.
  - [x] bootstrap
  - [x] history
  - [x] topic join
  - [x] channel leave
  - [x] server disconnect
- [x] IRC runtime tests using local test server.
- [ ] Integration tests using local InspIRCd and irssi where useful.
- [x] Frontend reducer tests for realtime event application.
- [x] Frontend component tests for the chat shell.
- [x] Frontend tests for slash command completion.
- [x] Frontend tests for notification permission states.
- [ ] Frontend tests for socket/backend failure states.
- [x] Headless Chromium tests for local-only landing topics and auth-protected chat route.
- [x] Run `npm test --prefix assets` for React changes.
- [x] Run targeted `mix test` during backend work.
- [x] Run `mix precommit` before completing implementation changes.

## Implementation sequence

- [ ] Phase 1: Stabilize frontend shell contracts.
  - [ ] Add leave buttons and popover menus.
  - [x] Add slash command popover UI.
  - [ ] Add connection health indicator UI.
  - [ ] Add reducer-level state model.
- [ ] Phase 2: Build backend buffer model.
  - [ ] Add buffer serialization.
  - [ ] Add bootstrap endpoint.
  - [ ] Add message history pagination.
  - [ ] Add user list payloads.
- [ ] Phase 3: Expand realtime channel.
  - [ ] Add channel push handlers.
  - [ ] Add reply contracts.
  - [ ] Add event contracts.
  - [ ] Add backend tests.
- [ ] Phase 4: Integrate IRC runtime.
  - [x] Use `ircxd`.
  - [ ] Normalize IRC events.
  - [ ] Persist messages and system lines.
  - [ ] Maintain user lists.
- [ ] Phase 5: Polish failure and notification behavior.
  - [ ] Socket disconnect UI.
  - [ ] Send retries.
  - [ ] Mention notification flow.
  - [ ] Retention pruning verification.
