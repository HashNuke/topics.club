# IRC command support remediation plan

## Purpose

Track the work required to make slash commands, raw IRC commands, and ircxd responses reliable and understandable in the topics.club UI.

This plan records gaps found during the August 25, 2026 review. Remediation work starts unchecked intentionally. A work item should be checked only after its implementation and relevant automated tests are complete; decision items are checked when the decision has been explicitly made and recorded here.

## Goals

- [ ] Every command shown in the UI has an accurate syntax and a working execution path.
- [ ] A successful command acknowledgement means the command was actually sent or completed, not silently ignored.
- [ ] Server replies and IRC errors reach an appropriate persisted buffer and appear in realtime.
- [ ] Stateful IRC operations cannot silently desynchronize IRC, backend, and UI state.
- [ ] The backend is the single source of truth for command definitions and availability.
- [ ] IRC channel types and private messages supported by ircxd are routed consistently.

## Status and priority conventions

- `[ ]` Not started or not yet verified.
- `[x]` Implemented and verified by automated tests. In the decision section only, `[x]` means the decision has been made.
- **P0** Correctness or misleading behavior that should be fixed first.
- **P1** Core command-response infrastructure needed for dependable command output.
- **P2** UX, policy, and maintainability improvements that build on the core infrastructure.

## Research basis and scope

This checklist treats “standard IRC commands” as the client-to-server command surface described by the IRC client protocol, plus the modern IRCv3 commands that the installed ircxd client exposes. The first group is not the same as “everything a server will accept”: some commands are connection-handshake internals, some require IRC-operator privileges, and some historical commands are obsolete. Supporting `/quote` therefore means parsing and classifying the complete command surface, then either executing it through a managed path or rejecting it explicitly and safely.

Research used for this plan:

- [RFC 2812: IRC Client Protocol](https://www.rfc-editor.org/rfc/rfc2812.html) for the wire grammar, the 15-parameter and 512-byte limits, command families, numerics, and the asynchronous request/reply model.
- [Modern IRC Client Protocol](https://modern.ircdocs.horse/) for current command behavior, ISUPPORT-driven limits, and identification of obsolete historical commands.
- [IRCv3 labeled-response](https://ircv3.net/specs/extensions/labeled-response) and [batch](https://ircv3.net/specs/extensions/batch) for request correlation, logical response boundaries, and `ACK` behavior.
- [IRCv3 standard replies](https://ircv3.net/specs/extensions/standard-replies) for command-aware `FAIL`, `WARN`, and `NOTE` handling.
- [IRCv3 capability negotiation](https://ircv3.net/specs/extensions/capability-negotiation) for why raw `CAP` changes cannot bypass ircxd's capability state machine.
- The checked-out `../ircxd/lib/ircxd/client.ex`, `message.ex`, and supporting modules for the exact typed APIs, validation, capabilities, events, and terminal events available to topics.club.

The researched constraints that drive the action items are:

- IRC parameters are not whitespace-delimited arguments. A final `:<trailing parameter>` may contain spaces, so `PRIVMSG Nick :hello there`, `PART #room :good night`, and `TOPIC #room :new topic` must each preserve the final text as one parameter.
- One request can produce zero, one, or many asynchronous replies. Multi-target commands such as `JOIN #a,#b key-a,key-b` and `PART #a,#b :reason` can partially succeed and produce a separate error for each failed target.
- Socket-write success is not server confirmation. Application state must change from the server's self-authored `JOIN`, `PART`, `NICK`, `KICK`, `TOPIC`, and `MODE` events or their defined replies.
- A label correlates one logical response, not necessarily one event. A labeled response can be a batch, an `ACK`, or—in failure cases—missing or incomplete, so command-specific terminal events and timeouts remain necessary.
- `FAIL`, `WARN`, and `NOTE` must be interpreted using both their command and code; the same reply code can mean different things for different commands.
- `CAP`, `AUTHENTICATE`, `PING`, `PONG`, `ERROR`, and `BATCH` participate in connection/protocol state machines. Raw access to them can invalidate ircxd's internal view even when the wire line itself is legal.

## Issues found

### CMD-01 — Most ircxd command responses are discarded

**Priority:** P0/P1

**Current behavior:** `Ircpipe.Irc.Session` handles selected events such as connection lifecycle, MOTD, notices, channel lifecycle, topics, IRC errors, and `/list`. Its final ircxd catch-all silently ignores the rest. ircxd already emits structured replies for WHO, WHOIS, WHOWAS, MODE and TOPIC queries, HELP, INFO, ADMIN, VERSION, TIME, STATS, ban/invite/exception lists, standard replies, and raw numerics.

**Impact:** Commands such as `/quote WHOIS nick`, `/quote MODE #channel`, and `/quote HELP` can show `Command accepted.` without ever showing their results. Send acceptance is also presented like command completion.

**Resolution:** Add a command-result pipeline that formats, persists, routes, and broadcasts supported ircxd responses. Preserve a safe raw-numeric fallback instead of silently discarding output.

### CMD-02 — Server-buffer plain text is a local-only fake message

**Priority:** P0

**Current behavior:** Non-slash text entered in the server buffer is appended only to React state. It is not sent to IRC and is not persisted. It may also be ignored entirely when there is no active channel, despite the server composer promising that it can message a service.

**Impact:** The UI appears to send a message that disappears after refresh.

**Resolution:** Make the server composer command-only unless and until it has an explicit target. Reject non-command text, do not append it locally, and provide accurate placeholder/help text.

### CMD-03 — `/topic` syntax does not match its advertised behavior

**Priority:** P0

**Current behavior:** The parser splits a topic containing spaces into multiple arguments, while execution accepts exactly `[channel, topic]`. The documented example therefore fails. The command description also promises topic viewing, but `[channel]` is rejected.

**Impact:** A common operator command fails for normal topics, and query behavior is misleadingly advertised.

**Resolution:** Parse the channel separately from the complete remaining topic. Support both topic query and topic set forms, then route ircxd topic replies to the channel buffer.

### CMD-04 — Private-message support is outbound-only

**Priority:** P0/P1

**Current behavior:** `/msg` sends a direct `PRIVMSG`, but inbound direct `PRIVMSG` events do not match the channel-only session handlers and are discarded. Direct notices do reach the server buffer. There is no private/query buffer model.

**Impact:** Users can initiate a private conversation but cannot reliably see replies.

**Resolution:** Route direct messages somewhere durable immediately, then implement an explicit query-buffer model if private conversations remain a supported product feature.

### CMD-05 — `/quote` can bypass application state and its permission is decorative

**Priority:** P0/P2

**Current behavior:** `/quote` is marked `advanced_user`, but the backend does not enforce `required_permission`. Raw `JOIN`, `PART`, `NICK`, `QUIT`, and messaging commands bypass normal persistence and reconciliation paths.

**Impact:** IRC state, database memberships, connection state, and visible buffers can diverge. The permission metadata gives a false sense of enforcement.

**Resolution:** Define and enforce a raw-command policy. Prefer native handlers for stateful commands and allow safe query commands by default. Either implement a real advanced-user capability or remove that permission label.

### CMD-06 — Non-`#` channel types are routed inconsistently

**Priority:** P0

**Current behavior:** The domain normalizes `#`, `&`, `+`, and `!` channel names, while inbound message, notice, and mode handlers match only targets beginning with `#`.

**Impact:** Messages and modes for channels such as `&local` can be discarded or misrouted to the server buffer.

**Resolution:** Centralize channel-target detection. Prefer the server's `CHANTYPES` ISUPPORT value; at minimum, consistently support the channel prefixes already accepted by the domain.

### CMD-07 — Command definitions are duplicated and errors are generic

**Priority:** P0/P2

**Current behavior:** React contains a hardcoded slash-command catalog even though the backend exposes command metadata and `command:suggest`. Backend reason codes are collapsed to `Command failed.` in the UI.

**Impact:** Client and server behavior can drift, permissions cannot be represented accurately, and users cannot correct invalid syntax or connection problems.

**Resolution:** Make backend command metadata authoritative and return typed, user-actionable command errors with usage information.

### CMD-08 — Successful nickname changes leave application state stale

**Priority:** P0

**Current behavior:** ircxd emits the nick-change event and the app broadcasts presence changes, but the owned connection nickname and IRC session state used by the application are not updated.

**Impact:** Subsequent locally persisted messages and self-detection can continue using the old nickname.

**Resolution:** Detect a self-nick change, persist the new nickname, update session state, and broadcast updated connection data to the UI.

### CMD-09 — Commands without a buffer can succeed as no-ops

**Priority:** P0

**Current behavior:** A parsed command with a missing `buffer_id` receives an `ok` reply without being executed.

**Impact:** The UI reports success for work that never happened.

**Resolution:** Reject context-dependent commands with `invalid_buffer` and disable command submission when the UI has no valid context.

### CMD-10 — `/quote` does not parse IRC message syntax

**Priority:** P0

**Current behavior:** `parse_raw_command/1` trims the input and splits it on every whitespace boundary. It loses the distinction between middle parameters and the final trailing parameter, does not explicitly reject client-forbidden numerics/source prefixes before the transport layer, and has no command-specific arity or target validation.

**Impact:** Valid lines such as `/quote PRIVMSG Nick :hello there`, `/quote PART #room :good night`, and `/quote TOPIC #room :new topic` are transmitted with the wrong parameter shape. The application also cannot reliably decide whether a `MODE` or `TOPIC` line is a query or mutation.

**Resolution:** Parse the raw body with IRC message grammar, reject client source prefixes and uncontrolled tags/numerics, and pass a typed command intent through a command registry before transmission.

### CMD-11 — Server-confirmed raw state changes are not reconciled durably

**Priority:** P0

**Current behavior:** ircxd already emits self `JOIN`, `PART`, `NICK`, `KICK`, `QUIT`, `MODE`, and `TOPIC` feedback, but the session handlers update only part of the in-memory presence state. A raw self `JOIN` does not create a `ChannelMembership`; a raw self `PART` or self-targeted `KICK` does not remove it; a self `NICK` does not update the owned connection; and raw `QUIT` is not distinguished from a transient disconnect.

**Impact:** IRC may accept the command while persistence, reconnect behavior, available buffers, and the React UI retain a conflicting state.

**Resolution:** Make server feedback authoritative for both native slash commands and parsed `/quote` commands. Use idempotent reconciliation handlers shared by all event sources, and model pending intent separately from confirmed durable state.

### CMD-12 — Channel membership conflates buffer identity, auto-join intent, and confirmed IRC state

**Priority:** P0

**Current behavior:** `ChannelMembership` is created before a native join is confirmed and is deleted immediately after a native PART is written. Deletion cascades to that membership's messages. The model has no pending, joined, failed, or left state and no independent auto-join preference.

**Impact:** Waiting for authoritative server feedback is difficult without either showing a membership as joined too early or deleting history when the user leaves. Raw joins/parts also have no durable lifecycle into which they can reconcile.

**Resolution:** Separate durable buffer identity and reconnect preference from live IRC membership state. The recommended model keeps/reuses the membership row, tracks pending/joined/left/error state and auto-join intent separately, and hides/archives a left buffer without destroying its retained history.

## Product and architecture decisions

Decisions marked complete below define the agreed implementation direction. Open decisions must be resolved before starting their dependent work.

- [x] **DEC-01:** Use the server buffer as the first-release destination for inbound and outbound private messages, with explicit sender, target, direction, and peer metadata.
  - First-class query buffers keyed by `{server_connection_id, normalized_nick}` remain the complete follow-up solution.
- [x] **DEC-02:** Parse known `/quote` commands into managed command intents and route them through the same execution/reconciliation paths as native slash commands.
  - Keep each stateful command denied at the raw transport boundary until its managed handler and server-confirmation tests are complete; enable commands one at a time from the registry.
  - Support stateful commands such as `JOIN`, `PART`, `NICK`, `QUIT`, `MODE`, `TOPIC`, `KICK`, `INVITE`, `AWAY`, `PRIVMSG`, and `NOTICE` through shared handlers rather than unrestricted `Session.raw/3` calls.
  - Keep classification argument-aware. For example, `MODE #room` is a query, `MODE #room +o Nick` is a mutation, `MODE #room +b` without a mask is commonly a list query, `TOPIC #room` is a query, and `TOPIC #room :` is a mutation that clears the topic.
  - Keep credential-bearing, registration, protocol-owned, destructive operator, numeric, and client-prefixed lines denied by default even when they are syntactically valid.
  - Safe query families include `WHO`, `WHOIS`, `WHOWAS`, `NAMES`, `LIST`, `MODE` queries, `TOPIC` queries, `MOTD`, `VERSION`, `ADMIN`, `LUSERS`, `TIME`, `INFO`, `HELP`, `STATS`, `LINKS`, `TRACE`, `USERHOST`, and `ISON`.
- [ ] **DEC-03:** Decide whether `advanced_user` is a real account capability, an opt-in preference, or metadata that should be removed.
- [x] **DEC-04:** Use existing timeline rows for first-release command output.
  - Use `command` rows for invocations/status, `notice` rows for results and private/service replies, and `error` rows for failures.
  - Defer grouped/collapsible transcript cards and specialized result renderers until the durable data pipeline is stable.
- [x] **DEC-05:** Preserve structured command and private-message metadata from the first release even when the simple timeline renderer only displays `body`.
  - Candidate fields include `command_id`, `command`, `result_type`, `sequence`, `target`, raw numeric code, `direction`, and `peer_nick`.
- [ ] **DEC-06:** Choose the database representation for the structured metadata required by DEC-05, such as a JSON/map message field or normalized storage.
- [x] **DEC-07:** Define terminal events per query family so `completed` has a precise meaning.
  - Examples include `who_end`, `whois_end`, `whowas_end`, `help_end`, `info_end`, `stats_end`, and `links_end`.
- [x] **DEC-08:** Treat ircxd `labeled_response` as correlation/lifecycle metadata for the underlying structured event, never as a second persisted result row.
- [x] **DEC-09:** Maintain an exhaustive ircxd event-disposition inventory. Every event must be classified as one or more of display, persist, state update, correlate, internal, or intentionally ignored.
- [x] **DEC-10:** Build and review the larger deferred UI work with Storybook stories after the correctness and persistence pipeline is stable.
- [x] **DEC-11:** Treat the server event as the source of truth for durable IRC state, regardless of whether the initiating command came from a native slash command, `/quote`, reconnect auto-join, another attached client, or a server-forced action.
  - Record a pending intent after local validation and successful transmission, but do not create/remove memberships or persist a new nick merely because the socket write succeeded.
  - Reconciliation must be idempotent because a command may be observed through structured, generic, labeled, replayed, or reconnect-derived events.
- [x] **DEC-12:** Use a command registry as the single executable specification for `/quote` support.
  - Each entry records syntax/arity, command class, sensitivity, required IRCv3 capability or ISUPPORT token, target expansion, execution adapter, expected success/error events, terminal rule, state reconciliation, output destination, redaction rule, and enabled status.
  - Known standard commands never fall through to an unclassified raw send.
  - Unknown vendor commands remain blocked until DEC-03 defines who may use advanced passthrough and what state-consistency guarantee the UI communicates.
- [ ] **DEC-13:** Decide whether service-authentication messages sent through `PRIVMSG`/`NOTICE` may be retained as ordinary message bodies or must use a dedicated non-persisted secret workflow.
  - Command-level redaction can reliably protect `PASS`, `OPER`, channel keys, `REGISTER`, and `VERIFY`; it cannot safely infer every network's NickServ/service syntax from arbitrary chat text.
- [ ] **DEC-14:** Confirm the channel-membership lifecycle representation required by CMD-12.
  - Recommended: keep `ChannelMembership` as the stable buffer/history identity, add separate auto-join intent plus pending/joined/left/error state and timestamps, reuse the row on rejoin, and stop cascading message deletion merely because IRC confirmed a PART/KICK.
  - If deletion-on-part is intentionally retained, explicitly accept history loss and define how late/replayed events avoid targeting a deleted buffer.

## Agreed release boundary

### First release: correctness using the existing timeline

- [ ] Complete the P0 correctness fixes and P1 command-result pipeline.
- [ ] Reuse existing timeline rows for all command invocations, results, private/service replies, and errors.
- [ ] Route private messages to the server buffer without losing their structured peer/direction metadata.
- [ ] Keep command output durable across refresh, reconnect, pagination, and retention pruning.
- [ ] Make the backend command catalog authoritative and expose actionable typed errors.
- [ ] Ship the managed `/quote` parser, registry, interim deny-by-default policy, and server-authoritative state reconciliation before enabling stateful raw command families.
- [ ] Limit first-release UI work to necessary correctness changes: composer behavior, statuses, errors, catalog data, and ordinary result rows.

### Deferred UI release: Storybook-reviewed components

- [ ] Add or configure Storybook for the production React components if the project does not already provide it.
- [ ] Add grouped and collapsible command transcript cards.
- [ ] Add specialized WHOIS, HELP, MODE, STATS, and other result presentations where they improve comprehension.
- [ ] Add first-class private/query buffers, sidebar entries, unread states, and conversation panes.
- [ ] Develop and review pending, completed, failed, timeout, empty, loading, disconnected, archived, mobile, and long-content states in Storybook.

## Phase 1 — P0 correctness fixes

### Server composer

- [ ] Remove the local-only server-message branch.
- [ ] Reject non-slash server-buffer submissions without mutating the timeline.
- [ ] Change the placeholder to accurate command examples such as `/msg NickServ help` and `/quote WHOIS nick`.
- [ ] Disable submission when there is no valid server or channel context.
- [ ] Add a visible explanation that normal conversation belongs in a channel or private-message buffer.
- [ ] Add frontend tests proving plain server text is neither displayed as sent nor submitted.

### Command context and acknowledgement semantics

- [ ] Remove the successful no-op for a missing `buffer_id`.
- [ ] Return a typed `invalid_buffer` error for commands requiring context.
- [ ] Distinguish these states in replies and UI copy:
  - [ ] parsed
  - [ ] accepted for transmission
  - [ ] sent to IRC
  - [ ] completed successfully, when completion can be known
  - [ ] failed or timed out
- [ ] Stop using the unconditional `Command accepted.` message as a completion indicator.
- [ ] Add backend and frontend tests for missing context and acknowledgement wording.

### Backend-owned command catalog

- [ ] Remove the hardcoded React command catalog.
- [ ] Include the authoritative command catalog in bootstrap or fetch it through one backend-owned API/channel contract.
- [ ] Filter or annotate commands by buffer context and user capability.
- [ ] Include name, usage, description, examples, availability, and permission policy.
- [ ] Keep autocomplete responsive by caching catalog data client-side rather than requiring a push for every keystroke.
- [ ] Add a discoverable command-help surface beyond prefix autocomplete.
- [ ] Add a contract test proving the UI catalog matches backend definitions.

### Typed errors and recovery

- [ ] Define stable backend command error codes.
- [ ] Include human-readable copy, usage, and recoverability metadata where appropriate.
- [ ] Map at least these errors in React:
  - [ ] unknown command
  - [ ] invalid arguments
  - [ ] invalid or missing buffer
  - [ ] invalid server
  - [ ] not connected
  - [ ] not joined or still joining
  - [ ] permission denied by policy
  - [ ] permission denied by IRC server
  - [ ] command timeout
  - [ ] list already in progress
- [ ] Preserve the submitted command in the error presentation without exposing secrets.
- [ ] Offer reconnect, retry, or corrected-usage actions where appropriate.

### Managed `/quote` parser and registry

- [ ] Replace `String.split/3` parsing with a dedicated `Ircpipe.Irc.RawCommand` parser built on, or behaviorally equivalent to, `Ircxd.Message.parse/1`.
- [ ] Parse and preserve the IRC command plus at most 15 parameters, including one final trailing parameter containing spaces or an empty string.
- [ ] Normalize command names case-insensitively while preserving parameter bytes and display text.
- [ ] Reject empty input, invalid command tokens, embedded `NUL`, `CR`, or `LF`, too many parameters, invalid UTF-8 when `UTF8ONLY` applies, and lines over ircxd's outbound wire limit.
- [ ] Reject a client-supplied source prefix and three-digit numeric command; numerics are server replies, not client commands.
- [ ] Reject message tags in the first release. Add tagged raw input only through a later explicit parser/policy that validates tag names, byte limits, active capabilities, and forbidden spoofable tags.
- [ ] Do not strip the leading colon from an empty or multiword final parameter. Verify these distinct meanings:
  - [ ] `TOPIC #room` queries the topic.
  - [ ] `TOPIC #room :` clears the topic.
  - [ ] `PART #room :good night` carries one reason parameter.
  - [ ] `PRIVMSG Nick :hello there` carries one body parameter.
- [ ] Add an `Ircpipe.Irc.CommandRegistry` entry for every command in the command-family inventory below.
- [ ] Require every registry entry to declare `managed_stateful`, `managed_message`, `query`, `protocol_owned`, `sensitive`, `operator`, `deprecated`, or `unsupported` classification.
- [ ] Make the registry select a typed ircxd API/executor for known commands; do not call unrestricted `Session.raw/3` for commands with application-managed effects.
- [ ] Deny registry entries by default and enable a command only after its parser, policy, feedback, reconciliation, error, timeout, persistence, and fake-server tests are complete.
- [ ] Return a typed policy error that states whether the command is not yet managed, protocol-owned, credential-bearing, operator-only, obsolete, or unknown; point to a native slash command when one exists.
- [ ] Never transmit a command rejected by parsing, registry policy, ownership checks, required capability checks, or connection state.
- [ ] Never persist or echo secret parameters. Store a registry-provided redacted display form rather than redacting an already-persisted raw line.

#### Command-registry coverage manifest

Each checkbox means that every named command has an explicit registry entry and classification. It does not mean every command is enabled; denied commands must be represented just as deliberately as enabled commands.

- [ ] **Managed state and moderation:** `JOIN`, `PART`, `NICK`, `QUIT`, `MODE`, `TOPIC`, `KICK`, `INVITE`, `AWAY`.
- [ ] **Managed messaging:** `PRIVMSG`, `NOTICE`.
- [ ] **Channel/user queries:** `NAMES`, `LIST`, `WHO`/WHOX, `WHOIS`, `WHOWAS`, `USERHOST`, `ISON`.
- [ ] **Server queries:** `MOTD`, `VERSION`, `ADMIN`, `LUSERS`, `TIME`, `STATS`, `HELP`, `INFO`, `LINKS`, `TRACE`.
- [ ] **Connection/registration/protocol-owned:** `PASS`, `USER`, `SERVICE`, `CAP`, `AUTHENTICATE`, `BATCH`, `PING`, `PONG`, `ERROR`, `STARTTLS`, `WEBIRC`.
- [ ] **Credential-bearing/operator/destructive:** `OPER`, `KILL`, `CONNECT`, `SQUIT`, `REHASH`, `RESTART`, `DIE`, `WALLOPS`.
- [ ] **Historical/optional service queries:** `SERVLIST`, `SQUERY`, `SUMMON`, `USERS`.
- [ ] **IRCv3/ircxd extensions:** `SETNAME`, `RENAME`, `MONITOR`, `MARKREAD`, `METADATA`, `CHATHISTORY`, `TAGMSG`, `REGISTER`, `VERIFY`, `REDACT`.
- [ ] **Unknown/vendor commands:** one deny-by-default classification with no transport fallback until the advanced-passthrough decision and consistency contract are complete.

### Shared command intents and server-authoritative reconciliation

- [ ] Implement the membership lifecycle chosen in DEC-14 before converting native/raw JOIN and PART to server-authoritative confirmation.
- [ ] If the recommended model is accepted, add explicit auto-join intent and pending/joined/left/error state, set `joined_at` only on confirmation, retain `left_at`/last error, and migrate existing rows as reconnect-enabled memberships without losing history.
- [ ] Make bootstrap/sidebar queries return only the lifecycle states intended to be visible while still allowing a rejoin to reuse retained history and buffer identity.
- [ ] Add a pending-intent model keyed by `command_id` with command, parsed parameters, expanded targets, originating buffer, transmission time, sensitivity, expected events, terminal rule, and timeout.
- [ ] Route native slash commands and equivalent `/quote` forms into the same intent/executor path; for example, `/join #a` and `/quote JOIN #a` must not maintain separate state logic.
- [ ] Treat successful ircxd send calls as `sent`, not `completed`, and do not perform confirmed durable mutations at send time.
- [ ] Reconcile state from self-authored or self-targeted server events even when no local pending intent exists. This covers server-forced actions, another attached client, reconnect state, and lost correlation.
- [ ] Compare nicknames and channel names with the server's ISUPPORT `CASEMAPPING`, and detect channels using `CHANTYPES` rather than ASCII lowercasing or a `#`-only match.
- [ ] Expand comma-separated targets before tracking intent and allow independent `completed`/`failed` outcomes per target.
- [ ] Preserve the key-to-channel association for multi-target `JOIN` without persisting or displaying channel keys.
- [ ] Make all reconciliation operations idempotent and transaction-safe so duplicate generic/labeled/replayed events do not duplicate memberships, removals, messages, or UI notifications.
- [ ] Resolve an event destination only after reconciliation. A self `JOIN` must ensure the membership/buffer exists before trying to record the join, topic, names, or mode output there.
- [ ] On disconnect, fail or suspend pending intents according to their command semantics, clear timers, and perform a full joined-channel/nick/capability reconciliation after registration resumes.
- [ ] Add redacted telemetry for unmatched success/error events and expired intents so missing mappings can be diagnosed without exposing message bodies, keys, or credentials.

### Core stateful `/quote` command reconciliation

- [ ] **`JOIN`:** Parse `JOIN <channels> [<keys>]`, including comma-separated channels/keys and the special `JOIN 0` leave-all form.
  - [ ] Track one pending outcome per channel and validate targets against `CHANTYPES`, `CHANLIMIT`, and known client-side limits without treating local validation as server authorization.
  - [ ] On a self `join` event, idempotently create/reactivate the `ChannelMembership`, emit `buffer:joined` when the UI does not already have it, update `joined_channels`, and then process topic/names/presence output.
  - [ ] On `403`, `405`, `471`, `473`, `474`, `475`, `476`, `477`, `FAIL JOIN`, or another target-specific rejection, fail only the affected channel, clear its pending state, and leave no active membership behind.
  - [ ] For `JOIN 0`, wait for self `PART` events and reconcile every confirmed departure instead of deleting all memberships at transmission time.
- [ ] **`PART`:** Parse `PART <channels> [<reason>]`, preserving a multiword or empty reason.
  - [ ] On each self `part` event, remove/archive the matching membership, emit `buffer:left`, update `joined_channels`, and retain history according to the chosen buffer-retention semantics.
  - [ ] Do not call `Chat.leave_channel/2` merely because `Ircxd.Client.part/3` accepted the write; fix the native `/part` path to use the same confirmation rule.
  - [ ] On `403`, `442`, `461`, `FAIL PART`, disconnect, or timeout, keep the membership unless later server state proves the user left.
- [ ] **`NICK`:** Parse exactly one nickname and track the previous and requested nick.
  - [ ] On a self `nick` event, update the persisted `ServerConnection.nickname`, replace the session's connection/current-nick state, update presence across every membership, and broadcast the connection change once.
  - [ ] Treat `431`, `432`, `433`, `436`, `437`, `501`, `502`, or `FAIL NICK` as rejection and retain the confirmed nick.
  - [ ] Ensure ircxd's registration-time nick retry does not silently choose a fallback nick for a user-initiated post-registration `NICK`; surface the rejection instead or explicitly reconcile any retry it performs.
- [ ] **`QUIT`:** Parse zero or one optional trailing reason and model it as an intentional connection stop.
  - [ ] Distinguish a requested quit from network loss so supervision/reconnect does not immediately reconnect against the user's intent.
  - [ ] Use server `ERROR`, transport close, or process termination as the terminal signal; set connection status, clear presence and pending intents, and preserve memberships/history according to the explicit manual-disconnect policy.
  - [ ] Redact or normalize quit reasons only if the product's message policy requires it; do not mislabel local send acceptance as completion.
- [ ] **`MODE`:** Classify using target type, parameter count, mode signs, and ISUPPORT `CHANMODES`, `PREFIX`, and list-mode tokens.
  - [ ] Support user/channel mode queries (`MODE <nick-or-channel>`) and list queries such as a ban/exception/invite list request without misclassifying them as mutations.
  - [ ] On confirmed channel mode events, update member prefixes/roles and any modeled channel state; on self user mode events/replies, update modeled operator/away/visibility state.
  - [ ] Complete a user query on `221`, a channel mode query on `324` plus optional creation time `329`, a ban list on `ban_list_end` (`368`), an invite-exception list on `invite_exception_list_end` (`347`), and an exception list on `exception_list_end` (`349`); use the labeled boundary when optional follow-up rows make a numeric boundary ambiguous.
  - [ ] Surface `472`, `481`, `482`, `501`, `502`, `696`, and standard failures without applying speculative changes.
  - [ ] Treat channel keys and other server-declared sensitive mode parameters as secrets in command display, persistence, telemetry, and logs.
- [ ] **`TOPIC`:** Distinguish query, set, and clear from the presence and value of the second parameter.
  - [ ] For queries, treat `331` as an empty terminal result; after `332`, include optional setter/time `333` and finish on the labeled boundary or a documented short fallback grace period. For mutations, update the channel only on the server `topic` event or equivalent confirmed reply.
  - [ ] Preserve a multiword topic exactly and surface `403`, `442`, `461`, `482`, and standard failures in the affected channel.
- [ ] **`KICK`:** Parse channel, one or more targets supported by the server, and an optional reason.
  - [ ] Update ordinary member presence for confirmed kicks; when the current user is the target, perform the same membership/buffer reconciliation as a self `PART`.
  - [ ] Do not change state on `401`, `403`, `441`, `461`, `476`, `481`, `482`, or a standard failure.
- [ ] **`INVITE`:** Parse exactly a nick and channel, display incoming invites, and use `341` or a labeled `ACK` as success without creating membership before a later self `JOIN`.
  - [ ] Route `401`, `403`, `442`, `443`, `461`, `482`, and standard failures to the originating/affected buffer.
- [ ] **`AWAY`:** Distinguish `AWAY` (clear) from `AWAY :message` (set), and preserve the full message.
  - [ ] Update self presence only on `305`, `306`, self `away`, or another authoritative response, and display standard failures without speculative status changes.

### `/topic`

- [ ] Parse `/topic #channel New topic with spaces` as `["#channel", "New topic with spaces"]`.
- [ ] Support `/topic #channel` as a query using `Ircxd.Client.topic/3` with no topic.
- [ ] Continue to validate that the channel belongs to the current user's connection.
- [ ] Route `topic_reply`, `topic_empty`, and `topic_who_time` to the relevant channel buffer.
- [ ] Update command usage, description, and examples to match implemented behavior.
- [ ] Add parser, channel, session, and UI tests for query, multiword set, invalid arguments, and server rejection.

### Channel target detection

- [ ] Add one shared channel-target predicate or target-routing function.
- [ ] Capture and retain `CHANTYPES` from ircxd ISUPPORT when available.
- [ ] Use the shared routing logic for inbound `PRIVMSG`, `NOTICE`, `MODE`, TOPIC, and related events.
- [ ] Provide a safe fallback consistent with the domain's `#&+!` support.
- [ ] Add tests using at least `#public` and `&local` targets.

### Nickname synchronization

- [ ] Detect whether an ircxd nick event changes the current user's nick.
- [ ] Persist the new nickname on the owned server connection.
- [ ] Replace the connection value inside the running IRC session state.
- [ ] Ensure outgoing persisted messages use the new nickname.
- [ ] Broadcast a connection update that React applies to the relevant server and buffers.
- [ ] Surface rejected nickname changes, including nick-in-use events, as actionable buffer errors.
- [ ] Add reconnect and post-change message tests.

### Immediate private-message safety

- [ ] Stop discarding inbound direct `PRIVMSG` events.
- [ ] Route inbound and outbound private messages to the owning server buffer for the first release, as chosen in DEC-01.
- [ ] Persist outgoing `/msg` bodies, not only a generic `Sent message` line.
- [ ] Preserve sender, target, service, hostmask, timestamp, and server connection metadata.
- [ ] Preserve `direction` and `peer_nick` metadata so later query-buffer work does not require another message-contract redesign.
- [ ] Route direct actions and notices consistently with direct messages.
- [ ] Add end-to-end tests for user and service replies.

### Managed `/quote` messaging commands

- [ ] **`PRIVMSG`:** Parse one or more comma-separated targets plus exactly one trailing body and dispatch through the shared channel/private messaging path.
  - [ ] Enforce joined-channel and owned-connection context, expand targets for routing, persist one canonical outgoing row per destination, and deduplicate `echo-message` feedback.
  - [ ] Detect CTCP `ACTION` and supported CTCP requests without letting raw control characters bypass formatting, security, or DCC policy.
  - [ ] Surface target-specific `401`, `404`, `407`, `411`, `412`, `413`, `414`, `415`, `417`, `482`, and standard failures; do not infer delivery merely from the absence of an error.
  - [ ] Define `sent` as local transport acceptance and a labeled `ACK` as server command acceptance, not proof that a human recipient received or read the message.
  - [ ] Define how service-authentication messages such as `PRIVMSG NickServ :IDENTIFY secret` are handled. Normal message bodies cannot be generically redacted, so any promise not to retain service credentials requires a dedicated secret-safe command flow and an explicit block on known credential forms.
- [ ] **`NOTICE`:** Parse targets/body like `PRIVMSG`, route through the same persistence/destination rules, and respect IRC's rule that automated replies must not be generated in response to a notice.
  - [ ] Represent server/service notices, channel notices, and direct notices consistently, and deduplicate echoed outbound notices when supported.
  - [ ] Apply the same `sent` versus server-accepted distinction as `PRIVMSG`; the protocol does not provide recipient delivery/read confirmation.
- [ ] Keep **`TAGMSG`** disabled in ordinary `/quote` until tagged input is deliberately supported; a tag-only message without validated client tags has no useful first-release behavior.
- [ ] Keep DCC sends, CTCP commands other than explicitly supported actions, and client-only tag behaviors behind separate opt-in policies and tests.

## Phase 2 — P1 command-result pipeline

### Command identity and correlation

- [ ] Generate a unique `command_id` in the client for every command submission.
- [ ] Include `command_id`, `buffer_id`, and input in `command:run` payloads.
- [ ] Return `command_id` in every success and error reply.
- [ ] Request the IRCv3 `labeled-response` capability when supported.
- [ ] Use ircxd labeled commands for correlatable raw/query commands.
- [ ] Extract the label from the underlying structured event and associate it with `command_id`.
- [ ] Use ircxd `labeled_response` only to update correlation, batching, or completion lifecycle state.
- [ ] Never persist both a structured event and its `labeled_response` wrapper as separate result rows.
- [ ] Define a chronological, ungrouped fallback for servers without labeled responses.
- [ ] Prevent pending-command state from leaking after completion, timeout, disconnect, or process termination.
- [ ] Add a query-family registry that defines expected result events and terminal events.
- [ ] Mark a command completed only after its terminal event or labeled-response boundary is observed.
- [ ] Mark a correlated IRC error as failed and an expired pending command as timed out.
- [ ] Cover at least WHO, WHOIS, WHOWAS, HELP, INFO, STATS, LINKS, MODE query, and TOPIC query completion rules.

### Standard query `/quote` command inventory

- [ ] Add registry syntax, routing, formatter, failure mapping, and terminal rules for channel/user queries:
  - [ ] `NAMES [<channels>]`: `names` rows followed by `names_end` (`366`) per channel; for no-target or multi-target forms, aggregate per-channel endings under the labeled boundary or a documented fallback timeout.
  - [ ] `LIST [<channels> [<server>]]`: `list_start`, `list_entry`, and `list_end` (`323`), integrated with the existing directory lifecycle.
  - [ ] `WHO <mask> [<flags>]` and supported WHOX shape: `who_reply`/`whox_reply` followed by `who_end` (`315`).
  - [ ] `WHOIS [<server>] <nicks>`: all structured WHOIS rows followed by `whois_end` (`318`) per requested nick/logical response.
  - [ ] `WHOWAS <nick> [<count> [<server>]]`: WHOWAS rows followed by `whowas_end` (`369`).
  - [ ] `USERHOST <nicks>`: one `userhost` (`302`) response or a correlated error.
  - [ ] `ISON <nicks>`: one `ison` (`303`) response or a correlated error.
- [ ] Add registry syntax, routing, formatter, failure mapping, and terminal rules for server queries:
  - [ ] `MOTD [<server>]`: `motd_start`/`motd` followed by `motd_end` (`376`), with `motd_missing` (`422`) as a terminal failure/empty result.
  - [ ] `VERSION [<server>]`: one `version` (`351`) response.
  - [ ] `ADMIN [<server>]`: `admin_start`, location rows, and `admin_email` (`259`) as the legacy terminal row, or a labeled boundary/error.
  - [ ] `LUSERS [<mask> [<server>]]`: all `lusers` rows, completed by the labeled boundary when available; define and test the numeric fallback boundary because networks vary after `255`/`265`/`266`.
  - [ ] `TIME [<server>]`: one `time` (`391`) response.
  - [ ] `STATS [<query> [<server>]]`: stats rows followed by `stats_end` (`219`).
  - [ ] `HELP [<subject>]`: `help_start`/`help` followed by `help_end` (`706`), with `524` as a terminal failure.
  - [ ] `INFO [<server>]`: info rows followed by `info_end` (`374`).
  - [ ] `LINKS [[<remote-server>] <mask>]`: links rows followed by `links_end` (`365`).
  - [ ] `TRACE [<target>]`: trace rows followed by `trace_end` (`262`) when supplied, otherwise a labeled boundary or documented timeout fallback.
  - [ ] `USERS [<server>]`: users rows followed by `users_end` (`394`), with `users_disabled` (`395`) terminal.
- [ ] Treat each multi-target query target as a separately trackable result where the protocol returns target-specific errors.
- [ ] Complete a single-row query when its response arrives, but still consume a labeled boundary/ACK without persisting a duplicate row.
- [ ] For a server without labeled responses, match by command family plus normalized target and keep overlapping indistinguishable requests chronological; document that correlation is best-effort in this fallback.

### ircxd event-disposition inventory

- [ ] Add an explicit inventory covering every public ircxd client event used or emitted by the installed ircxd version.
- [ ] Allow events to have multiple actions, such as `[:state, :display, :persist]` for a join.
- [ ] Classify every event as one or more of display, persist, state update, correlate, internal, or intentionally ignored.
- [ ] Document why every intentionally ignored event is not exposed by topics.club.
- [ ] Replace silent unknown-event handling with redacted, rate-limited logging or telemetry.
- [ ] Add or expose a canonical ircxd event-name catalog if needed to make coverage testable.
- [ ] Add a contract test that fails when ircxd adds an event without a topics.club disposition.

### Event formatting and routing

- [ ] Add a focused formatter/router module for ircxd events.
- [ ] Have the formatter return a stable destination, message kind, human-readable body, and structured metadata.
- [ ] Format and route these response families:
  - [ ] WHO and WHOX
  - [ ] WHOIS and WHOWAS
  - [ ] user and channel MODE queries
  - [ ] TOPIC query, setter, and timestamp
  - [ ] HELP
  - [ ] INFO
  - [ ] ADMIN
  - [ ] VERSION
  - [ ] TIME
  - [ ] LUSERS
  - [ ] STATS and TRACE
  - [ ] LINKS and USERS
  - [ ] ban lists
  - [ ] invite lists and invite exceptions
  - [ ] exception lists
  - [ ] standard `FAIL`, `WARN`, and `NOTE` replies
  - [ ] supported miscellaneous numerics
- [ ] Add a safe fallback for unrecognized `raw` events and numeric replies.
- [ ] Continue ignoring ircxd's duplicate generic `message` notification when a structured event has already been handled.
- [ ] Persist each structured event exactly once even when ircxd also emits generic and labeled wrappers.
- [ ] Redact credentials and sensitive authentication material from commands and output before persistence or broadcast.

### Persistence and realtime delivery

- [ ] Persist command invocation rows in the originating buffer or explicitly selected server buffer.
- [ ] Persist each result row with ordering and correlation metadata.
- [ ] Preserve the DEC-05 metadata contract even though the first-release timeline uses only ordinary message rows.
- [ ] Route channel-specific replies to their channel when a membership exists.
- [ ] Route server-wide and unmatched replies to the owning server buffer.
- [ ] Broadcast persisted output through the existing versioned buffer event contract.
- [ ] Ensure history pagination returns command output after reconnect or refresh.
- [ ] Define unread-counter behavior for command results initiated by the current user.
- [ ] Ensure retention pruning treats command output consistently with other messages.

### `/list` integration

- [ ] Preserve the existing dedicated channel-directory result and UI.
- [ ] Add `command_id` correlation without duplicating list entries into the generic transcript unless intentionally desired.
- [ ] Keep timeout, concurrent-list, navigation-away, and reconnect behavior covered.

## Phase 3 — P2 command UX and policy

### Expanded raw-command policy

- [ ] Expand the Phase 1 registry into the complete managed/deny policy chosen in DEC-02 and DEC-12.
- [ ] Keep policy decisions argument-aware and conservative for server-specific syntax, mode sets, and vendor extensions.
- [ ] Continue routing stateful operations through shared managed handlers even after they are enabled for `/quote`.
- [ ] Enforce or remove the `advanced_user` metadata according to DEC-03.
- [ ] Treat channel-operator requirements as IRC-server authorization and surface resulting IRC errors clearly.
- [ ] Add audit-safe command logging that excludes credentials.
- [ ] Add tests proving denied raw commands are never transmitted.

### Registration, protocol-owned, privileged, and historical commands

- [ ] **Registration credentials:** Keep raw `PASS`, `USER`, and `SERVICE` denied after connection startup.
  - [ ] The connection configuration/ircxd registration flow remains the only owner of these commands; `PASS` values must never enter command rows, error echoes, telemetry, or logs.
  - [ ] Return a specific `registration_command_managed` policy error instead of allowing the server's `462` after the secret has already been exposed to the application pipeline.
- [ ] **Capability/SASL state machine:** Keep raw `CAP`, `AUTHENTICATE`, and `BATCH` denied.
  - [ ] Expose safe capability inspection through ircxd's managed `cap_list`/ISUPPORT state if desired.
  - [ ] Any future capability toggle must call ircxd's request/disable APIs and wait for complete `ACK`/`NAK`; it must never send raw `CAP REQ` behind ircxd's active-capability state.
  - [ ] SASL reauthentication, if added, must use a secret-safe dedicated flow rather than `/quote AUTHENTICATE`.
- [ ] **Transport/registration extensions:** Keep raw `STARTTLS` and `WEBIRC` denied. TLS mode and trusted-proxy identity must be established by connection configuration before registration; they cannot be changed safely by an already-registered browser command.
- [ ] **Transport keepalive:** Keep raw `PING`, `PONG`, and `ERROR` denied because ircxd owns keepalive and connection termination. If a user-facing latency check is desired, implement a managed command with a generated opaque token and matched `pong` event.
- [ ] **Numerics and prefixes:** Reject client-sent numeric commands and source prefixes even if the generic message parser accepts their wire shape.
- [ ] **Operator authentication:** Keep `/quote OPER <name> <password>` denied because it carries a credential. A future oper-login surface must require TLS, redact both fields, use a dedicated executor, and complete on `youre_oper` (`381`), user `MODE`, or an explicit error.
- [ ] **Destructive/operator commands:** Default-deny `KILL`, `CONNECT`, `SQUIT`, `REHASH`, `RESTART`, `DIE`, and server-specific equivalents.
  - [ ] If the product later supports IRC operators, require an explicit account capability, per-command confirmation for destructive actions, typed ircxd APIs, redacted audit records, and server reply/error handling before enabling each command.
  - [ ] Do not confuse server authorization (`481`, `483`, `491`, `723`, or `FAIL`) with topics.club's product permission; both gates must pass.
- [ ] **Operator messaging:** Classify `WALLOPS` separately from destructive commands; enable only with a defined oper-capability policy and route inbound/outbound wallops to the server buffer.
- [ ] **Historical service/optional commands:** Mark `SERVICE`, `SERVLIST`, `SQUERY`, `SUMMON`, and `USERS` with their modern status in the registry.
  - [ ] Keep obsolete registration/service commands denied; queries such as `SERVLIST`/`USERS` may be enabled only if ircxd emits displayable terminal replies and the server advertises/supports them.
  - [ ] Never advertise an obsolete command in autocomplete merely because `Ircxd.Client` exposes a helper for protocol completeness.

### IRCv3 and ircxd-supported extension commands

- [ ] Keep extension commands capability-gated and disabled until their application-state and output semantics are implemented; “ircxd can transmit it” is not sufficient.
- [ ] **`SETNAME`:** Preserve the trailing realname, require/observe the `setname` capability, update shared presence only on the self `setname` event, and handle `FAIL SETNAME` without speculative state.
- [ ] **`RENAME`:** Require `draft/channel-rename`; on confirmed rename, atomically migrate the membership/buffer identity, history routing, pending intents, sidebar state, and presence from old channel to new channel. Reject raw use until this is tested.
- [ ] **`MONITOR`:** Parse `+`, `-`, `C`, `L`, and `S` subcommands, enforce ISUPPORT limits, maintain a confirmed monitor set from online/offline/list/end events, and decide whether results are state-only or also displayed.
- [ ] **`MARKREAD`:** Require `draft/read-marker`; distinguish get/set shapes and reconcile the server marker with local unread state without moving a local marker backward or marking unseen local history as read accidentally.
- [ ] **`METADATA`:** Require `metadata`; distinguish `GET`, `SUB`, `UNSUB`, `SET`, and `SYNC`, declare which mutations are permitted, correlate metadata replies/end conditions, and redact sensitive key values.
- [ ] **`CHATHISTORY`:** Require `draft/chathistory`; validate subcommand, selector, target, limit, and server-advertised limits; consume the reply batch as one logical response; and deduplicate imported events against locally retained messages using message IDs before allowing raw use.
- [ ] **`TAGMSG`:** Require `message-tags`, validate allowed client-only tags, route each tag by its registered behavior, and do not render a blank chat row by default.
- [ ] **Account registration `REGISTER`/`VERIFY`:** Keep denied in `/quote`; passwords, emails, and verification codes require a dedicated secret-safe workflow, TLS, capability checks, and standard-reply handling.
- [ ] **`REDACT`:** Require the message-redaction capability and a local deletion/tombstone model before enabling; reconcile only confirmed redactions and preserve appropriate audit/history behavior.
- [ ] Add registry entries for any other ircxd extension API introduced by dependency upgrades, with default status `unsupported` until all required fields and tests are supplied.

### Command transcript UI — deferred Storybook work

- [ ] Render command invocations distinctly from ordinary chat messages.
- [ ] Show pending, sent, completed, failed, and timed-out states without overstating success.
- [ ] Group correlated multiline output under its command.
- [ ] Add collapsible presentation for verbose results such as WHOIS, HELP, and STATS.
- [ ] Preserve plain accessible text for screen readers and copy/paste.
- [ ] Keep unknown/raw numeric output readable even without a specialized renderer.
- [ ] Make command errors visually distinct and attach them to the originating command when possible.
- [ ] Verify behavior on narrow/mobile layouts and with long unbroken IRC parameters.
- [ ] Add Storybook stories for every status, result family, error, mobile layout, and long-content edge case before integrating the richer components.

### First-class private/query buffers — deferred Storybook work

- [ ] Add a durable query-buffer identity keyed by server and normalized peer nick.
- [ ] Add query buffers to bootstrap, history, unread counts, and sidebar ordering.
- [ ] Open or focus a query buffer after `/msg`.
- [ ] Create or reuse a query buffer for inbound direct messages.
- [ ] Track peer nick changes without losing conversation history.
- [ ] Define close/archive behavior without sending an IRC command.
- [ ] Add mention/notification rules for private messages.
- [ ] Add retention, pagination, reconnect reconciliation, and mobile UI tests.
- [ ] Add Storybook stories for query sidebar rows, unread states, conversation panes, empty history, archived state, connection failure, and mobile layouts.

## Command-specific completion checklist

### `/join`

- [ ] Requires a valid owned server or channel context.
- [ ] Uses the native membership path rather than raw IRC state mutation.
- [ ] Reports join pending, confirmed, and rejected states accurately.
- [ ] Removes or marks a membership appropriately after a rejected join.

### `/list`

- [ ] Continues to open the dedicated directory.
- [ ] Shows typed timeout, disconnected, and concurrent-request errors.
- [ ] Does not reopen after the user navigates away.

### `/part` and `/leave`

- [ ] Support the active channel with no explicit argument if retained as intended behavior.
- [ ] Keep usage/help consistent with optional or required channel syntax.
- [ ] Reconcile server rejection or disconnect behavior with membership state.

### `/me`

- [ ] Works only in a joined channel or supported private buffer.
- [ ] Produces one canonical action row without echo duplication.
- [ ] Shows typed not-joined and disconnected errors.

### `/msg`

- [ ] Persists and displays the outgoing body in its chosen destination.
- [ ] Displays inbound replies.
- [ ] Handles service replies sent as either `PRIVMSG` or `NOTICE`.
- [ ] Rejects missing target or message with accurate usage.

### `/nick`

- [ ] Updates IRC, session, persistence, presence, and UI state after confirmation.
- [ ] Displays rejection reasons without claiming success.

### `/topic`

- [ ] Supports query and multiword set forms.
- [ ] Displays current topic, empty topic, setter, and timestamp replies.
- [ ] Displays operator/permission failures in the affected channel.

### `/quote`

- [ ] Parses IRC trailing parameters, empty trailing values, limits, and invalid wire characters correctly.
- [ ] Resolves every known command through the registry; no known command reaches an unclassified raw fallback.
- [ ] Routes managed stateful commands through the same intent/executor/reconciler used by native slash commands.
- [ ] Reconciles `JOIN`, `PART`, `NICK`, `QUIT`, `MODE`, `TOPIC`, `KICK`, `INVITE`, and `AWAY` from authoritative server feedback.
- [ ] Routes and persists `PRIVMSG` and `NOTICE` through the normal message pipeline with echo deduplication and accurate delivery semantics.
- [ ] Correlates, displays, persists, and completes every enabled query according to its declared result and terminal events.
- [ ] Applies capability, ISUPPORT, context, ownership, operator, and sensitive-command policy before transmission.
- [ ] Uses a safe display fallback for unknown server numerics/events without treating unknown client commands as safe to send.
- [ ] Never logs server passwords, SASL payloads, channel keys, account-registration secrets, verification codes, or operator credentials.
- [ ] Cannot silently mutate application-managed state, interfere with ircxd protocol state, or claim completion from a socket write.
- [ ] Documents disabled standard, obsolete, operator, and extension commands with a specific reason and any safer supported alternative.

## Automated test plan

### Backend parser and policy tests

- [ ] Test every advertised command's valid forms.
- [ ] Test missing, excess, and multiword arguments.
- [ ] Test context requirements.
- [ ] Add table-driven round-trip fixtures for every command registry entry, including trailing parameters, empty trailing parameters, comma-separated target lists, maximum arity, mixed-case command names, and maximum wire length.
- [ ] Test rejection of source prefixes, tags in the first release, numeric commands, `NUL`/`CR`/`LF`, too many parameters, oversized lines, and invalid `UTF8ONLY` payloads.
- [ ] Test managed, protocol-owned, sensitive, operator, deprecated, unsupported, and unknown policy outcomes.
- [ ] Test argument-aware `MODE` query, list query, and mutation classification using representative `CHANMODES`/`PREFIX` values.
- [ ] Test `TOPIC` query versus set versus clear classification.
- [ ] Test `JOIN`/`PART` target expansion, partial success, `JOIN 0`, and channel-key redaction.
- [ ] Test that denied raw commands never reach the IRC transport.
- [ ] Test that sensitive input is redacted before persistence, broadcast, telemetry, and logs.
- [ ] Add a registry completeness test against the documented standard/modern command inventory so a known command cannot accidentally use an unknown-command fallback.

### IRC session integration tests

- [ ] Extend `IrcTestServer` scenarios for WHOIS, MODE query, TOPIC query, HELP, standard replies, and unknown numerics.
- [ ] Verify each reply is persisted in the expected buffer.
- [ ] Verify each persisted reply is broadcast in realtime.
- [ ] Verify labeled and unlabeled response correlation paths.
- [ ] Verify each supported query reaches `completed` only through its declared terminal event or labeled-response boundary.
- [ ] Verify structured, generic, and labeled forms of one IRC reply produce exactly one persisted result.
- [ ] Verify the event-disposition inventory covers the installed ircxd event catalog.
- [ ] Verify `&local` and at least one ordinary `#channel` route identically.
- [ ] Verify direct `PRIVMSG`, direct `NOTICE`, and direct action routing.
- [ ] Verify self-nick state after success and rejection.
- [ ] Verify command cleanup after timeout and disconnect.
- [ ] Verify both native and `/quote` forms enter the same reconciliation path and produce equivalent final state.
- [ ] Verify raw self `JOIN` creates/reactivates a membership before channel output is recorded, including after no pending local intent.
- [ ] Verify multi-channel `JOIN` can succeed for one target and fail for another without leaking keys or phantom buffers.
- [ ] Verify raw and native `PART` retain membership until self `PART`, retain it on rejection/timeout, and remove/archive it once on confirmation.
- [ ] Verify `JOIN 0`, self-targeted `KICK`, server-forced join/part, and replayed duplicate events reconcile idempotently.
- [ ] Verify raw `NICK` updates the confirmed connection/session/UI nick only after self feedback and does not invoke registration fallback behavior on rejection.
- [ ] Verify raw `QUIT` is treated as intentional and does not trigger an unintended reconnect loop.
- [ ] Verify MODE query/list/mutation, TOPIC query/set/clear, INVITE, and AWAY success and failure terminal rules.
- [ ] Verify raw `PRIVMSG`/`NOTICE` trailing bodies, multi-target routing, direct-message destination, CTCP action handling, echo deduplication, and no false `delivered` status.
- [ ] Verify protocol-owned and sensitive commands are not sent even over a live fake-server connection.
- [ ] Verify overlapping labeled and unlabeled queries, partial labeled batches, missing ACKs, late responses, and target-specific errors clean up pending state safely.

### Phoenix channel contract tests

- [ ] Verify `command_id` round-trips on success and error.
- [ ] Verify missing buffers are rejected.
- [ ] Verify typed errors and usage metadata.
- [ ] Verify command-result buffer events use the versioned event contract.
- [ ] Verify ownership checks for every supplied server, channel, or query buffer.

### React tests

- [ ] Verify command catalog data comes from the backend.
- [ ] Verify autocomplete is context aware.
- [ ] Verify server-buffer plain text cannot appear sent locally.
- [ ] Verify parsed, sent, completed, failed, and timeout states.
- [ ] Verify ordinary first-release timeline rows display command results and private messages without requiring transcript cards or query buffers.
- [ ] Verify raw fallback output renders in ordinary first-release timeline rows.
- [ ] Verify multiline result grouping after the deferred transcript components are introduced.
- [ ] Verify exact actionable errors instead of generic `Command failed.`.
- [ ] Verify private-message destination and unread behavior.
- [ ] Verify refresh/reconciliation preserves command output.
- [ ] Verify accessibility roles, keyboard operation, and mobile layout.

### Regression and quality checks

- [ ] Run focused Elixir command, session, and channel tests during development.
- [ ] Run focused React and realtime-client tests during development.
- [ ] Run `mix precommit` after all changes are complete.
- [ ] Confirm no unrelated user changes were overwritten.

## First-release definition of done

- [ ] All Phase 1 P0 correctness work and Phase 2 P1 command-result work is complete and covered by regression tests.
- [ ] The backend command catalog is authoritative and typed errors give users actionable feedback.
- [ ] `/quote` uses the IRC-aware parser and complete command registry before any transmission; source prefixes, numerics, uncontrolled tags, protocol-owned commands, secrets, unknown commands, and not-yet-managed stateful commands are denied.
- [ ] Enabled standard stateful `/quote` commands share native execution/reconciliation and update durable state only from server feedback, including multi-target partial outcomes.
- [ ] Argument-aware `MODE` query/list/mutation and `TOPIC` query/set/clear behavior is implemented and tested.
- [ ] Private messages are durably visible in the server buffer with metadata needed for future query buffers.
- [ ] Command output is durably visible through ordinary timeline rows with accurate status and error semantics.
- [ ] Every ircxd event has an explicit tested disposition, and labeled/generic wrappers do not create duplicates.
- [ ] Deferred transcript-card and query-buffer UI work is not required to ship the correctness release.
- [ ] Structured metadata is stable enough to build deferred Storybook fixtures without another transport-contract redesign.
- [ ] `mix precommit` passes.

## Full-plan definition of done

- [ ] All P0 issues are resolved and covered by regression tests.
- [ ] Every advertised command has an accurate command-specific completion checklist.
- [ ] No supported ircxd command response is silently discarded without an intentional, documented reason.
- [ ] The UI never presents a local-only message or write-to-socket acknowledgement as server-confirmed success.
- [ ] Direct messages and every supported channel type have an explicit routing destination.
- [ ] Every standard IRC client command and ircxd-supported extension has an explicit command-registry disposition; every enabled `/quote` shape has documented parsing, execution, feedback, terminal, reconciliation, routing, redaction, and test behavior.
- [ ] `/quote` has a documented, enforced, and tested security/state policy, and native and raw forms cannot diverge in final state.
- [ ] Command output survives refresh and reconnect through normal buffer history.
- [ ] Backend command metadata is authoritative in the UI.
- [ ] Typed errors give users enough information to correct or retry a failed command.
- [ ] Deferred transcript and query-buffer components have been reviewed through their agreed Storybook stories.
- [ ] `mix precommit` passes.
