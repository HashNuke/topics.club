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
- The checked-out ircxd client at commit `6a14084`, especially `Ircxd.ClientCommand`, `Ircxd.CommandSpec`, `Ircxd.Client.Event`, and `Ircxd.Client.Info`, for the protocol-owned parsing, validation, command metadata, event metadata, and cached connection state available to topics.club.

The August 25 ircxd integration update moved several responsibilities out of this application. This plan assumes topics.club will consume these APIs rather than duplicate them:

- `Ircxd.ClientCommand.parse/2` owns `/quote` wire parsing and the default rejection of tags, source prefixes, numerics, injection characters, excess parameters, and oversized lines. `Ircxd.Client.transmit/2` applies live capability, transport-security, and `UTF8ONLY` validation.
- `Ircxd.CommandSpec` owns reusable command syntax, broad family, required capabilities, relevant ISUPPORT tokens, sensitive parameter positions, result events, terminal events, partial-success hints, and argument-aware `MODE`/`TOPIC` classification. The topics.club registry adds product policy, execution, routing, persistence, and reconciliation only.
- `Ircxd.Client.Event` envelopes own label, batch, raw-message, server-time, terminal, derivative, and duplicate-message metadata. `Ircxd.Client.Event.names/0` is the canonical event catalog.
- `Ircxd.Client.Info`, adapter callback context, normalized `source_self?`/`target_self?` flags, and `Ircxd.ISupport` own cached protocol state, casemapping-aware identity, and channel-type interpretation.
- ircxd now preserves the confirmed nickname after a rejected post-registration `NICK` and treats helper, raw, and transmitted `QUIT` commands as intentional disconnects.

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

**Current behavior:** `TopicsClub.Irc.Session` handles selected events such as connection lifecycle, MOTD, notices, channel lifecycle, topics, IRC errors, and `/list`. Its final ircxd catch-all silently ignores the rest. ircxd already emits structured replies for WHO, WHOIS, WHOWAS, MODE and TOPIC queries, HELP, INFO, ADMIN, VERSION, TIME, STATS, ban/invite/exception lists, standard replies, and raw numerics.

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

**Resolution:** Centralize channel-target detection around `Ircxd.ISupport.channel?/2` using ircxd's cached connection info, and align domain validation with the same negotiated `CHANTYPES` behavior and fallback.

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

**Resolution:** Parse the raw body with `Ircxd.ClientCommand.parse/2`, combine `Ircxd.CommandSpec` with topics.club product policy, and pass the resulting managed intent through the application command registry before transmission.

### CMD-11 — Server-confirmed raw state changes are not reconciled durably

**Priority:** P0

**Current behavior:** ircxd emits casemapping-aware self `JOIN`, `PART`, `NICK`, `KICK`, `QUIT`, `MODE`, and `TOPIC` feedback and distinguishes an intentional `QUIT` from transport loss, but the session handlers update only part of the application state. A raw self `JOIN` does not create a `ChannelMembership`; a raw self `PART` or self-targeted `KICK` does not remove it; and a self `NICK` does not update the owned connection.

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
- [x] **DEC-02:** Parse `/quote` with `Ircxd.ClientCommand`, classify it with `Ircxd.CommandSpec`, then route known commands into managed command intents that share the same execution/reconciliation paths as native slash commands.
  - Keep each stateful command denied at the raw transport boundary until its managed handler and server-confirmation tests are complete; enable commands one at a time from the registry.
  - Support stateful commands such as `JOIN`, `PART`, `NICK`, `QUIT`, `MODE`, `TOPIC`, `KICK`, `INVITE`, `AWAY`, `PRIVMSG`, and `NOTICE` through shared handlers rather than unrestricted `Session.raw/3` calls.
  - Keep classification argument-aware. For example, `MODE #room` is a query, `MODE #room +o Nick` is a mutation, `MODE #room +b` without a mask is commonly a list query, `TOPIC #room` is a query, and `TOPIC #room :` is a mutation that clears the topic.
  - Keep credential-bearing, registration, protocol-owned, destructive operator, numeric, and client-prefixed lines denied by default even when they are syntactically valid.
  - Safe query families include `WHO`, `WHOIS`, `WHOWAS`, `NAMES`, `LIST`, `MODE` queries, `TOPIC` queries, `MOTD`, `VERSION`, `ADMIN`, `LUSERS`, `TIME`, `INFO`, `HELP`, `STATS`, `LINKS`, `TRACE`, `USERHOST`, and `ISON`.
- [x] **DEC-03:** Remove the decorative `advanced_user` label. `/quote` availability is determined per command by the backend registry; unknown/vendor passthrough remains denied.
- [x] **DEC-04:** Use existing timeline rows for first-release command output.
  - Use one updatable `command` row for invocation/status and additional `command` rows for structured results. Keep private/service replies in their ordinary message/notice rows and expose failures through invocation status metadata plus the inline composer error.
  - Defer grouped/collapsible transcript cards and specialized result renderers until the durable data pipeline is stable.
- [x] **DEC-05:** Preserve structured command and private-message metadata from the first release even when the simple timeline renderer only displays `body`.
  - Candidate fields include `command_id`, `command`, `result_type`, `sequence`, `target`, raw numeric code, `direction`, and `peer_nick`.
- [x] **DEC-06:** Store the structured metadata required by DEC-05 in a JSON/map `messages.metadata` field; do not add normalized result tables unless later query needs justify them.
- [x] **DEC-07:** Consume ircxd's result and terminal-event metadata per query family so `completed` has a precise meaning; retain application timeouts for incomplete or unlabeled responses.
- [x] **DEC-08:** Treat ircxd `labeled_response` as correlation/lifecycle metadata for the underlying structured event, never as a second persisted result row.
- [x] **DEC-09:** Use `Ircxd.Client.Event.names/0` as ircxd's canonical event catalog. Explicitly handle the events topics.club consumes and send everything else through a safe, redacted, rate-limited fallback rather than duplicating ircxd's full inventory.
- [x] **DEC-10:** Build and review the larger deferred UI work with Storybook stories after the correctness and persistence pipeline is stable.
- [x] **DEC-11:** Treat the server event as the source of truth for durable IRC state, regardless of whether the initiating command came from a native slash command, `/quote`, reconnect auto-join, another attached client, or a server-forced action.
  - Record a pending intent after local validation and successful transmission, but do not create/remove memberships or persist a new nick merely because the socket write succeeded.
  - Reconciliation must be idempotent because a command may be observed through structured, generic, labeled, replayed, or reconnect-derived events.
- [x] **DEC-12:** Use a topics.club command registry as the single product-policy and execution layer for `/quote`, composed with `Ircxd.CommandSpec` as the protocol specification.
  - ircxd supplies syntax, command family, sensitivity, capability/ISUPPORT requirements, and result/terminal hints. The application supplies enabled status, product permission, target expansion, execution adapter, application-specific errors/timeouts, state reconciliation, output destination, and any stricter redaction rule.
  - Known standard commands never fall through to an unclassified raw send.
  - Unknown vendor commands remain blocked until DEC-03 defines who may use advanced passthrough and what state-consistency guarantee the UI communicates.
- [x] **DEC-13:** Retain `PRIVMSG`/`NOTICE` service messages as ordinary private-message history. Do not claim generic service-secret detection; explicitly warn that `/msg` is retained and keep known credential commands such as `PASS`, `OPER`, `REGISTER`, and `VERIFY` denied.
- [x] **DEC-14:** Keep `ChannelMembership` as the stable buffer/history identity, with separate auto-join intent plus pending/joined/left/error state and timestamps. Reuse the row on rejoin and never cascade message deletion merely because IRC confirmed a PART/KICK.

## Agreed release boundary

### First release: correctness using the existing timeline

- [ ] Complete the P0 correctness fixes and P1 command-result pipeline.
- [x] Reuse existing timeline rows for all command invocations, results, private/service replies, and errors.
- [x] Route private messages to the server buffer without losing their structured peer/direction metadata.
- [x] Keep command output durable across refresh, reconnect, pagination, and retention pruning.
- [x] Make the backend command catalog authoritative and expose actionable typed errors.
- [x] Ship the managed `/quote` parser, registry, interim deny-by-default policy, and server-authoritative state reconciliation before enabling stateful raw command families.
- [x] Limit first-release UI work to necessary correctness changes: composer behavior, statuses, errors, catalog data, and ordinary result rows.

### Deferred UI release: Storybook-reviewed components

- [ ] Add or configure Storybook for the production React components if the project does not already provide it.
- [ ] Add grouped and collapsible command transcript cards.
- [ ] Add specialized WHOIS, HELP, MODE, STATS, and other result presentations where they improve comprehension.
- [ ] Add first-class private/query buffers, sidebar entries, unread states, and conversation panes.
- [ ] Develop and review pending, completed, failed, timeout, empty, loading, disconnected, archived, mobile, and long-content states in Storybook.

## Phase 1 — P0 correctness fixes

### Server composer

- [x] Remove the local-only server-message branch.
- [x] Reject non-slash server-buffer submissions without mutating the timeline.
- [x] Change the placeholder to accurate command examples such as `/msg NickServ help` and `/quote WHOIS nick`.
- [x] Disable submission when there is no valid server or channel context.
- [x] Add a visible explanation that normal conversation belongs in a channel or private-message buffer.
- [x] Add frontend tests proving plain server text is neither displayed as sent nor submitted.

### Command context and acknowledgement semantics

- [x] Remove the successful no-op for a missing `buffer_id`.
- [x] Return a typed `invalid_buffer` error for commands requiring context.
- [ ] Distinguish these states in replies and UI copy:
  - [ ] parsed
  - [ ] accepted for transmission
  - [ ] sent to IRC
  - [ ] completed successfully, when completion can be known
  - [ ] failed or timed out
- [x] Stop using the unconditional `Command accepted.` message as a completion indicator.
- [x] Add backend and frontend tests for missing context and acknowledgement wording.

### Backend-owned command catalog

- [x] Remove the hardcoded React command catalog.
- [x] Include the authoritative command catalog in bootstrap or fetch it through one backend-owned API/channel contract.
- [x] Filter or annotate commands by buffer context and user capability.
- [x] Include name, usage, description, examples, availability, and permission policy.
- [x] Keep autocomplete responsive by caching catalog data client-side rather than requiring a push for every keystroke.
- [ ] Add a discoverable command-help surface beyond prefix autocomplete.
- [ ] Add a contract test proving the UI catalog matches backend definitions.

### Typed errors and recovery

- [x] Define stable backend command error codes.
- [x] Include human-readable copy, usage, and recoverability metadata where appropriate.
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
- [x] Preserve the submitted command in the error presentation without exposing secrets.
- [ ] Offer reconnect, retry, or corrected-usage actions where appropriate.

### Managed `/quote` parser and registry

- [x] Replace `String.split/3` parsing with `Ircxd.ClientCommand.parse/2` using its default tag, source-prefix, and numeric rejection policy; pass the returned `%Ircxd.Message{}` unchanged into policy resolution.
- [x] Map stable `Ircxd.ClientCommand` parse errors and live `Ircxd.Client.transmit/2` validation errors to typed, actionable application errors without duplicating ircxd's wire parser or validator.
- [x] Resolve `Ircxd.CommandSpec.classify/3` with the current cached `Ircxd.Client.Info` from `connection_info/1` (or adapter context inside callbacks), then merge it with the topics.club registry's product classification and policy.
- [x] Validate command-specific arity and parameter shape in the application policy before execution; `Ircxd.ClientCommand` validates IRC wire grammar and `Ircxd.CommandSpec.syntax` is descriptive, not an executable arity validator.
- [x] Give every command returned by `Ircxd.CommandSpec.commands/0` an application disposition such as managed, enabled query, protocol-owned, denied-sensitive, denied-operator, or unsupported.
- [x] Make the registry produce a policy-validated `%Ircxd.Message{}` and send it through `Ircxd.Client.transmit/2`; do not retain an unrestricted `Session.raw/3` bypass for application-managed effects.
- [ ] Enable each command only after its parser, policy, feedback, reconciliation, error, timeout, persistence, and representative fake-server tests are complete; the initial query allowlist still needs family-by-family coverage.
- [x] Return a typed policy error that states whether the command is not yet managed, protocol-owned, credential-bearing, operator-only, or unknown; point to a native slash command when one exists.
- [x] Never transmit a command rejected by parsing, registry policy, ownership checks, required capability checks, or connection state.
- [x] Never persist or echo secret parameters. Build the redacted display form from `Ircxd.CommandSpec.sensitive_positions` plus any stricter application rules before storing the command.

#### Command-registry coverage

Do not maintain a second hand-written manifest or a tautological coverage test for ircxd's focused command surface. Resolve commands from `Ircxd.CommandSpec` at runtime, add only explicit denials for protocol commands not exposed there (such as `USER`, `SERVICE`, `PING`, `ERROR`, `STARTTLS`, `WEBIRC`, and `DIE`), and give every other known-but-disabled command the shared `not_yet_managed` disposition. Unknown/vendor commands use one deny-by-default disposition with no transport fallback.

### Shared command intents and server-authoritative reconciliation

- [x] Implement the membership lifecycle chosen in DEC-14 before converting native/raw JOIN and PART to server-authoritative confirmation.
- [x] If the recommended model is accepted, add explicit auto-join intent and pending/joined/left/error state, set `joined_at` only on confirmation, retain `left_at`/last error, and migrate existing rows as reconnect-enabled memberships without losing history.
- [x] Make bootstrap/sidebar queries return only the lifecycle states intended to be visible while still allowing a rejoin to reuse retained history and buffer identity.
- [ ] Add a pending-intent model keyed by `command_id` with command, parsed parameters, expanded targets, originating buffer, transmission time, sensitivity, expected events, terminal rule, and timeout.
- [ ] Route native slash commands and equivalent `/quote` forms into the same intent/executor path; for example, `/join #a` and `/quote JOIN #a` must not maintain separate state logic.
- [x] Treat successful ircxd send calls as `sent`, not `completed`, and do not perform confirmed durable mutations at send time.
- [x] Reconcile state from self-authored or self-targeted server events even when no local pending intent exists. This covers server-forced actions, another attached client, reconnect state, and lost correlation.
- [x] Consume ircxd's event-time `source_self?`/`target_self?` flags and `Info.self_nick?/2` for self decisions, use cached casemapping normalization for other identifier comparisons, and use `Ircxd.ISupport.channel?/2` for target routing.
- [ ] Expand comma-separated targets before tracking intent and allow independent `completed`/`failed` outcomes per target.
- [ ] Preserve the key-to-channel association for multi-target `JOIN` without persisting or displaying channel keys.
- [ ] Make all reconciliation operations idempotent and transaction-safe so duplicate generic/labeled/replayed events do not duplicate memberships, removals, messages, or UI notifications.
- [x] Resolve an event destination only after reconciliation. A self `JOIN` must ensure the membership/buffer exists before trying to record the join, topic, names, or mode output there.
- [ ] On disconnect, fail or suspend pending intents according to their command semantics, clear timers, and reconcile durable joined-channel state after registration resumes while consuming ircxd's reset/repopulated client-info snapshot for nick and capabilities.
- [ ] Add redacted telemetry for unmatched success/error events and expired intents so missing mappings can be diagnosed without exposing message bodies, keys, or credentials.

### Core stateful `/quote` command reconciliation

- [ ] **`JOIN`:** Parse `JOIN <channels> [<keys>]`, including comma-separated channels/keys and the special `JOIN 0` leave-all form.
  - [ ] Track one pending outcome per channel and validate targets against `CHANTYPES`, `CHANLIMIT`, and known client-side limits without treating local validation as server authorization.
  - [x] On a self `join` event, idempotently create/reactivate the `ChannelMembership`, emit `buffer:joined` when the UI does not already have it, update `joined_channels`, and then process topic/names/presence output.
  - [ ] On `403`, `405`, `471`, `473`, `474`, `475`, `476`, `477`, `FAIL JOIN`, or another target-specific rejection, fail only the affected channel, clear its pending state, and leave no active membership behind.
  - [ ] For `JOIN 0`, wait for self `PART` events and reconcile every confirmed departure instead of deleting all memberships at transmission time.
- [x] **`PART`:** Parse `PART <channels> [<reason>]`, preserving a multiword or empty reason.
  - [x] On each self `part` event, remove/archive the matching membership, emit `buffer:left`, update `joined_channels`, and retain history according to the chosen buffer-retention semantics.
  - [x] Do not call `Chat.leave_channel/2` merely because `Ircxd.Client.part/3` accepted the write; fix the native `/part` path to use the same confirmation rule.
  - [x] On `403`, `442`, `461`, `FAIL PART`, disconnect, or timeout, keep the membership unless later server state proves the user left.
- [ ] **`NICK`:** Parse exactly one nickname and track the previous and requested nick.
  - [x] On a self `nick` event, update the persisted `ServerConnection.nickname`, replace the application's session connection value, update presence across every membership, and broadcast the connection change once; ircxd already updates its confirmed current nick before delivery.
  - [ ] Treat `431`, `432`, `433`, `436`, `437`, `501`, `502`, or `FAIL NICK` as rejection and retain the confirmed nick.
- [ ] **`QUIT`:** Parse zero or one optional trailing reason and model it as an intentional connection stop.
  - [ ] Consume ircxd's intentional disconnect lifecycle event; set application connection status, clear presence and pending intents, and preserve memberships/history according to the explicit manual-disconnect policy.
  - [ ] Redact or normalize quit reasons only if the product's message policy requires it; do not mislabel local send acceptance as completion.
- [ ] **`MODE`:** Use `Ircxd.CommandSpec.classify/3` with the cached client info to distinguish user/channel queries, list queries, and mutations.
  - [ ] On confirmed channel mode events, update member prefixes/roles and any modeled channel state; on self user mode events/replies, update modeled operator/away/visibility state.
  - [ ] Complete queries from the command spec's terminal hints or a labeled boundary; define only the application fallback for query shapes whose spec has no terminal event.
  - [ ] Surface `472`, `481`, `482`, `501`, `502`, `696`, and standard failures without applying speculative changes.
  - [ ] Redact the mode parameters identified by `Ircxd.CommandSpec.sensitive_positions` from command display, persistence, telemetry, and logs.
- [ ] **`TOPIC`:** Use `Ircxd.CommandSpec.classify/3` to distinguish query from mutation while preserving set versus clear from the parsed second parameter.
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

- [x] Parse `/topic #channel New topic with spaces` as `["#channel", "New topic with spaces"]`.
- [x] Support `/topic #channel` as a managed query with no topic parameter.
- [x] Continue to validate that the channel belongs to the current user's connection.
- [x] Route `topic_reply`, `topic_empty`, and `topic_who_time` to the relevant channel buffer.
- [x] Update command usage, description, and examples to match implemented behavior.
- [ ] Add parser, channel, session, and UI tests for query, multiword set, invalid arguments, and server rejection.

### Channel target detection

- [x] Add one shared target-routing function backed by `Ircxd.ISupport.channel?/2` and the cached `client_info.isupport` supplied by ircxd.
- [x] Use the shared routing logic for inbound `PRIVMSG`, `NOTICE`, `MODE`, TOPIC, and related events.
- [x] Align domain channel validation with ircxd's negotiated `CHANTYPES` behavior and `#`/`&` fallback.
- [x] Add tests using hash-prefixed and `&local` targets.

### Nickname synchronization

- [x] Use the nick event's ircxd-provided `source_self?` flag to identify a confirmed self change.
- [x] Persist the new nickname on the owned server connection.
- [x] Replace the connection value inside the running IRC session state.
- [x] Ensure outgoing persisted messages use the new nickname.
- [x] Broadcast a connection update that React applies to the relevant server and buffers.
- [x] Surface rejected nickname changes, including nick-in-use events, as actionable buffer errors.
- [ ] Add reconnect and post-change message tests.

### Immediate private-message safety

- [x] Stop discarding inbound direct `PRIVMSG` events.
- [x] Route inbound and outbound private messages to the owning server buffer for the first release, as chosen in DEC-01.
- [x] Persist outgoing `/msg` bodies, not only a generic `Sent message` line.
- [x] Preserve sender, target, service, hostmask, timestamp, and server connection metadata.
- [x] Preserve `direction` and `peer_nick` metadata so later query-buffer work does not require another message-contract redesign.
- [x] Route direct actions and notices consistently with direct messages.
- [ ] Add end-to-end tests for user and service replies.

### Managed `/quote` messaging commands

- [x] **`PRIVMSG`:** Parse one or more comma-separated targets plus exactly one trailing body and dispatch through the shared channel/private messaging path.
  - [x] Enforce joined-channel and owned-connection context, expand targets for routing, persist one canonical outgoing row per destination, and deduplicate `echo-message` feedback.
  - [x] Detect CTCP `ACTION` and supported CTCP requests without letting raw control characters bypass formatting, security, or DCC policy.
  - [ ] Surface target-specific `401`, `404`, `407`, `411`, `412`, `413`, `414`, `415`, `417`, `482`, and standard failures; do not infer delivery merely from the absence of an error.
  - [x] Define `sent` as local transport acceptance and a labeled `ACK` as server command acceptance, not proof that a human recipient received or read the message.
  - [x] Define how service-authentication messages such as `PRIVMSG NickServ :IDENTIFY secret` are handled. Normal message bodies cannot be generically redacted, so any promise not to retain service credentials requires a dedicated secret-safe command flow and an explicit block on known credential forms.
- [x] **`NOTICE`:** Parse targets/body like `PRIVMSG`, route through the same persistence/destination rules, and respect IRC's rule that automated replies must not be generated in response to a notice.
  - [x] Represent server/service notices, channel notices, and direct notices consistently, and deduplicate echoed outbound notices when supported.
  - [x] Apply the same `sent` versus server-accepted distinction as `PRIVMSG`; the protocol does not provide recipient delivery/read confirmation.
- [x] Keep **`TAGMSG`** disabled in ordinary `/quote` until tagged input is deliberately supported; a tag-only message without validated client tags has no useful first-release behavior.
- [x] Keep DCC sends, CTCP commands other than explicitly supported actions, and client-only tag behaviors behind separate opt-in policies and tests.

## Phase 2 — P1 command-result pipeline

### Command identity and correlation

- [x] Generate a unique `command_id` in the client for every command submission.
- [x] Include `command_id`, `buffer_id`, and input in `command:run` payloads.
- [x] Return `command_id` in every success and error reply.
- [x] Request the IRCv3 `batch` and `labeled-response` capabilities when supported.
- [x] Use ircxd labeled commands for correlatable raw/query commands.
- [x] Start ircxd in `events: :envelope` mode and associate `Ircxd.Client.Event.label` with `command_id` without reparsing payloads or raw messages.
- [x] Use envelope `derivative?` and ircxd's `labeled_response` lifecycle status for correlation/completion, while using `Ircxd.CommandSpec.terminal_events` as the command-specific terminal source; never persist a derivative wrapper as another result row.
- [x] Define a chronological, ungrouped fallback for servers without labeled responses.
- [x] Prevent pending-command state from leaking after completion, timeout, disconnect, or process termination.
- [x] Use `Ircxd.CommandSpec.result_events` and `terminal_events` as the query lifecycle source; supplement them only with application timeout/fallback rules where ircxd declares no terminal event.
- [x] Mark labeled commands completed or failed from ircxd's lifecycle result, and mark an application-expired pending command as timed out.

### Standard query `/quote` command inventory

- [ ] Add application policy, routing, formatting, and failure mapping for enabled channel/user queries (`NAMES`, `LIST`, `WHO`, `WHOIS`, `WHOWAS`, `USERHOST`, and `ISON`), consuming syntax and lifecycle hints from `Ircxd.CommandSpec`.
- [ ] Add application policy, routing, formatting, and failure mapping for enabled server queries (`MOTD`, `VERSION`, `ADMIN`, `LUSERS`, `TIME`, `STATS`, `HELP`, `INFO`, `LINKS`, `TRACE`, and `USERS`), consuming syntax and lifecycle hints from `Ircxd.CommandSpec`.
- [ ] Define and test an application fallback boundary only for an enabled query whose command spec has no terminal event or whose server omits the expected terminal event.
- [ ] Treat each multi-target query target as a separately trackable result where the protocol returns target-specific errors.
- [ ] Complete a single-row query when its response arrives, but still consume a labeled boundary/ACK without persisting a duplicate row.
- [ ] For a server without labeled responses, match by command family plus normalized target and keep overlapping indistinguishable requests chronological; document that correlation is best-effort in this fallback.

### ircxd event-disposition inventory

- [x] Keep `Ircxd.Client.Event.names/0` as the canonical inventory instead of maintaining a duplicate application manifest.
- [x] Give explicitly consumed events whichever display, persistence, state, and correlation actions the product requires.
- [x] Replace silent unknown-event handling with redacted, rate-limited logging or telemetry.
- [x] Let new or intentionally unconsumed ircxd events use that safe fallback so an ircxd update does not create busywork or expose raw payloads.

### Event formatting and routing

- [x] Add a focused formatter/router module for ircxd events.
- [x] Have the formatter/router combination select a stable destination, message kind, human-readable body, and structured metadata.
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
- [x] Add a safe fallback for unrecognized numeric `raw` events that shows only the numeric and final description.
- [x] Use event-envelope `derivative?` metadata to persist each server result exactly once while still consuming generic and labeled lifecycle views where needed.
- [x] Redact credentials and sensitive authentication material from commands and output before persistence or broadcast.

### Persistence and realtime delivery

- [x] Persist command invocation rows in the originating buffer or explicitly selected server buffer.
- [x] Persist each result row with ordering and correlation metadata.
- [x] Preserve the DEC-05 metadata contract even though the first-release timeline uses only ordinary message rows.
- [x] Route channel-specific replies to their channel when a membership exists.
- [x] Route server-wide and unmatched replies to the owning server buffer.
- [x] Broadcast persisted output through the existing versioned buffer event contract.
- [x] Ensure history pagination returns command output after reconnect or refresh.
- [ ] Define unread-counter behavior for command results initiated by the current user.
- [x] Ensure retention pruning treats command output consistently with other messages.

### `/list` integration

- [ ] Preserve the existing dedicated channel-directory result and UI.
- [x] Add `command_id` correlation without duplicating list entries into the generic transcript unless intentionally desired.
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
  - [ ] Any future capability toggle must call ircxd's request/disable APIs and wait for complete `ACK`/`NAK`; it must never send raw `CAP REQ` behind ircxd's active-capability state.
  - [ ] SASL reauthentication, if added, must use a secret-safe dedicated flow rather than `/quote AUTHENTICATE`.
- [ ] **Transport/registration extensions:** Keep raw `STARTTLS` and `WEBIRC` denied. TLS mode and trusted-proxy identity must be established by connection configuration before registration; they cannot be changed safely by an already-registered browser command.
- [ ] **Transport keepalive:** Keep raw `PING`, `PONG`, and `ERROR` denied because ircxd owns keepalive and connection termination. If a user-facing latency check is desired, implement a managed command with a generated opaque token and matched `pong` event.
- [ ] **Operator authentication:** Keep `/quote OPER <name> <password>` denied because it carries a credential. A future oper-login surface must require TLS, redact both fields, use a dedicated executor, and complete on `youre_oper` (`381`), user `MODE`, or an explicit error.
- [ ] **Destructive/operator commands:** Default-deny `KILL`, `CONNECT`, `SQUIT`, `REHASH`, `RESTART`, `DIE`, and server-specific equivalents.
  - [ ] If the product later supports IRC operators, require an explicit account capability, per-command confirmation for destructive actions, typed ircxd APIs, redacted audit records, and server reply/error handling before enabling each command.
  - [ ] Do not confuse server authorization (`481`, `483`, `491`, `723`, or `FAIL`) with topics.club's product permission; both gates must pass.
- [ ] **Operator messaging:** Classify `WALLOPS` separately from destructive commands; enable only with a defined oper-capability policy and route inbound/outbound wallops to the server buffer.
- [ ] **Historical service/optional commands:** Mark `SERVICE`, `SERVLIST`, `SQUERY`, `SUMMON`, and `USERS` with their modern status in the registry.
  - [ ] Keep obsolete registration/service commands denied; queries such as `SERVLIST`/`USERS` may be enabled only if ircxd emits displayable terminal replies and the server advertises/supports them.
  - [ ] Never advertise an obsolete command in autocomplete merely because `Ircxd.Client` exposes a helper for protocol completeness.

### IRCv3 and ircxd-supported extension commands

- [ ] Keep extension commands disabled until their application-state and output semantics are implemented; use `Ircxd.CommandSpec.required_capabilities` for policy messaging and let ircxd enforce the live transport capability check.
- [ ] **`SETNAME`:** Update shared presence only on the self `setname` event and handle `FAIL SETNAME` without speculative state.
- [ ] **`RENAME`:** Require `draft/channel-rename`; on confirmed rename, atomically migrate the membership/buffer identity, history routing, pending intents, sidebar state, and presence from old channel to new channel. Reject raw use until this is tested.
- [ ] **`MONITOR`:** Parse `+`, `-`, `C`, `L`, and `S` subcommands, enforce ISUPPORT limits, maintain a confirmed monitor set from online/offline/list/end events, and decide whether results are state-only or also displayed.
- [ ] **`MARKREAD`:** Require `draft/read-marker`; distinguish get/set shapes and reconcile the server marker with local unread state without moving a local marker backward or marking unseen local history as read accidentally.
- [ ] **`METADATA`:** Require `metadata`; distinguish `GET`, `SUB`, `UNSUB`, `SET`, and `SYNC`, declare which mutations are permitted, correlate metadata replies/end conditions, and redact sensitive key values.
- [ ] **`CHATHISTORY`:** Require `draft/chathistory`; validate subcommand, selector, target, limit, and server-advertised limits; consume the reply batch as one logical response; and deduplicate imported events against locally retained messages using message IDs before allowing raw use.
- [ ] **`TAGMSG`:** Require `message-tags`, validate allowed client-only tags, route each tag by its registered behavior, and do not render a blank chat row by default.
- [ ] **Account registration `REGISTER`/`VERIFY`:** Keep denied in `/quote`; passwords, emails, and verification codes require a dedicated secret-safe workflow, TLS, capability checks, and standard-reply handling.
- [ ] **`REDACT`:** Require the message-redaction capability and a local deletion/tombstone model before enabling; reconcile only confirmed redactions and preserve appropriate audit/history behavior.

### Command transcript UI — deferred Storybook work

- [ ] Render command invocations distinctly from ordinary chat messages.
- [ ] Show pending, sent, completed, failed, and timed-out states without overstating success.
- [ ] Group correlated multiline output under its command.
- [ ] Add collapsible presentation for verbose results such as WHOIS, HELP, and STATS.
- [ ] Preserve plain accessible text for screen readers and copy/paste.
- [x] Keep unknown/raw numeric output readable even without a specialized renderer.
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

- [ ] Uses `Ircxd.ClientCommand.parse/2` with its safe defaults and maps its stable errors without maintaining a second IRC wire parser.
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
- [ ] Add focused integration fixtures proving `/quote` passes `Ircxd.ClientCommand` results unchanged for trailing and empty trailing parameters and maps representative parser/transmit errors; leave exhaustive wire-parser and validator coverage in ircxd.
- [ ] Test managed, protocol-owned, sensitive, operator, deprecated, unsupported, and unknown policy outcomes.
- [ ] Add a contract test proving policy resolution consumes `Ircxd.CommandSpec.classify/3` without replacing its argument-aware `MODE`/`TOPIC`, sensitivity, or lifecycle metadata.
- [ ] Test `JOIN`/`PART` target expansion, partial success, `JOIN 0`, and channel-key redaction.
- [ ] Test that denied raw commands never reach the IRC transport.
- [ ] Test that sensitive input is redacted before persistence, broadcast, telemetry, and logs.

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
- [ ] Verify raw `NICK` updates the confirmed connection/session/UI nick only after `source_self?` feedback and leaves application state unchanged on ircxd's structured rejection event.
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
- [ ] `/quote` uses `Ircxd.ClientCommand` and the application registry composed with `Ircxd.CommandSpec` before any transmission; source prefixes, numerics, uncontrolled tags, protocol-owned commands, secrets, unknown commands, and not-yet-managed stateful commands are denied.
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
