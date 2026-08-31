# Dumb pipe and engine reattachment plan

## Status

Proposed requirements and implementation checklist. The architecture is agreed at a high level;
the independent transport core now exists under `apps/topics_club_wirekeeper`, but engine
integration has not started. It is not included in a production release or deployment definition.
The current API, adapter boundary, and exclusions are documented in `docs/wirekeeper.md`.
Production deployment remains explicitly out of scope while engine attachment and resume are built
and validated. Every integration iteration will use the resettable `testvps` and its local
synthetic IRC server.

This plan extends the gateway/engine split in `docs/app-split.md`. A gateway deployment already
leaves the engine and IRC connections running, but restarting the engine closes those connections.
The dumb pipe creates a smaller, more stable process-lifetime boundary in front of the engine.

## Desired topology

```text
IRC servers
    |
    | TCP/TLS
    v
+-----------------------------------------+
| Dumb pipe BEAM node                     |
|                                         |
| Owns sockets and answers IRC PING       |
| Maps connection record IDs to sockets   |
| Relays lines while engine is attached   |
| Counts traffic discarded during a gap   |
+--------------------+--------------------+
                     |
                     | Distributed Erlang
                     v
+-----------------------------------------+
| Engine BEAM node                        |
|                                         |
| IRC protocol and session state          |
| Persistence and application behavior    |
| Reattaches after an engine restart      |
+--------------------+--------------------+
                     |
                     | Distributed Erlang
                     v
+-----------------------------------------+
| Gateway BEAM node                       |
| Phoenix, APIs, websocket and PWA        |
+-----------------------------------------+
```

The pipe is a separate OTP application, release, BEAM node, operating-system process, and systemd
service. Restarting or deploying the engine must not restart the pipe. The pipe should change so
rarely that ordinary engine and gateway development never requires a pipe deployment.

The pipe is not a bouncer and not a second engine. It owns transport continuity, not IRC
application behavior.

## Connection identity

The pipe maintains an in-memory registry keyed by `server_connections.id`. That record identifies
one user's configured connection to one IRC network and is globally unique in the TopicsClub
database.

Conceptually:

```text
server_connection_id 42
  -> upstream TCP/TLS socket
  -> connection generation abc123
  -> attached engine consumer or none
  -> transport status
  -> detached-at timestamp
  -> discarded line and byte counts for the current gap
```

The pipe treats the record ID as an opaque key. It does not connect to PostgreSQL, load the record,
authorize the user, or understand its application meaning.

Every newly opened upstream socket receives a unique generation. Attach, send, and close operations
include that generation so a stale engine process cannot affect a replacement socket that happens
to use the same database record ID.

## Required behavior

### Socket ownership

- [ ] The pipe exclusively owns every upstream TCP/TLS socket and its TLS state.
- [ ] The engine never receives or owns the upstream operating-system file descriptor.
- [ ] The pipe relays IRC lines between its socket and the attached engine consumer.
- [ ] Losing the engine node or consumer detaches the consumer without closing the upstream socket.
- [ ] The pipe closes an upstream socket only after an explicit generation-matched close request, an
  upstream close/error, or termination of the pipe itself.
- [ ] The pipe never infers an upstream close from an engine disconnect.
- [ ] The pipe does not automatically reconnect a closed upstream connection. The engine retains
  connection policy and decides whether and when to open another generation.

### IRC PING ownership

- [ ] The pipe owns IRC PING/PONG handling at all times, including while the engine is attached.
- [ ] The engine and `Ircxd.Client` do not send a second PONG for a PING handled by the pipe.
- [ ] PING detection supports valid tagged or prefixed IRC messages rather than matching an unsafe
  raw string prefix.
- [ ] PING/PONG bypasses engine attachment and relay backpressure so an engine outage cannot cause
  an IRC timeout.
- [ ] PING is not written to application history and is not counted as discarded gap traffic.

### Engine attachment

- [ ] At most one engine consumer may be attached to a connection generation.
- [ ] The pipe detects engine process or node loss and moves affected connections to detached state.
- [ ] A restarted engine can list open connection IDs, generations, and transport statuses.
- [ ] The engine reattaches each authoritative active `server_connections.id` to its open generation.
- [ ] The engine opens a new generation only when no usable pipe connection exists and normal
  desired-state policy permits reconnection.
- [ ] After authoritative reconciliation, the engine explicitly closes pipe connections whose
  records were paused or deleted.
- [ ] Attaching to an existing generation does not send NICK, USER, PASS, SASL, CAP negotiation, or
  automatic JOIN commands again.

### Traffic during an engine restart

The pipe does not promise message replay. The accepted gap is only the interval after the engine
consumer detaches and before the replacement engine attaches.

- [ ] While an engine consumer is attached, IRC traffic is never silently discarded.
- [ ] If delivery to the attached consumer fails, the pipe first marks the generation detached;
  traffic observed after that transition belongs to the explicit gap.
- [ ] While detached, the pipe continues reading the upstream socket so TCP backpressure does not
  make the IRC server close the connection.
- [ ] While detached, the pipe answers PING and discards other inbound IRC lines instead of
  retaining a replay buffer.
- [ ] The pipe counts complete discarded IRC lines and discarded bytes per generation and detach
  episode.
- [ ] Reattachment returns a gap summary before live relay resumes.
- [ ] The engine treats a non-zero gap as potentially missing messages and state changes.
- [ ] The engine resynchronizes the minimum necessary IRC state after a gap without reconnecting or
  rejoining blindly.
- [ ] No arbitrary per-connection message buffer or resource-based replay sizing is part of the
  initial implementation. Measurements may justify a later, separately designed buffer.

Example reattachment result:

```text
connection_id: 42
generation: abc123
gap: true
discarded_lines: 17
discarded_bytes: 2381
detached_for_ms: 4100
```

### Resuming engine protocol state

The pipe remains ignorant of nicknames, channels, users, capabilities, ISUPPORT, application
messages, memberships, notifications, and remedies. The engine owns mid-session resume.

- [ ] Separate the IRC protocol/session state machine from direct socket ownership.
- [ ] Add an engine transport that sends and receives IRC lines through the pipe contract.
- [ ] Preserve enough engine-owned protocol state to attach to an existing generation without
  replaying registration.
- [ ] Use authoritative database state and targeted IRC queries to reconcile after a reported gap.
- [ ] Do not issue mass JOINs merely because the engine restarted; the upstream connection is
  already joined.
- [ ] Do not manufacture missing chat messages.
- [ ] If safe resume cannot be established, close and reconnect only that generation through the
  existing paced recovery path. Do not affect other connections.

The exact protocol-state snapshot and reconciliation queries must be frozen before resume is
implemented. They belong to the engine, not the pipe.

### Minimal pipe contract

The names describe responsibilities and are not frozen wire encodings:

```text
OPEN connection_id, transport_options
ATTACH connection_id, expected_generation
SEND connection_id, generation, IRC line
CLOSE connection_id, generation
LIST
DIAGNOSTICS
```

Pipe-to-engine results and events:

```text
OPENED connection_id, generation
ATTACHED connection_id, generation, gap_summary
DATA connection_id, generation, IRC line
UPSTREAM_CLOSED connection_id, generation, reason
STALE_GENERATION connection_id, expected, actual
```

- [ ] Define a small versioned contract using plain data only.
- [ ] Contract values contain no PIDs, socket handles, exceptions, functions, Ecto structs, or
  credentials.
- [ ] Unknown additive fields are ignored within a compatible protocol version.
- [ ] Malformed requests fail only that request and never terminate another connection.
- [ ] Sending has an explicit accepted, rejected, stale-generation, or ambiguous result.
- [ ] The contract contains no escape hatch for invoking arbitrary pipe functions.

### Security and observability

- [ ] Pipe and engine communicate only over the host's private Distributed Erlang interface using
  the shared secret cookie and fixed firewall-restricted distribution ports.
- [ ] Only the statically configured engine node may attach or issue commands.
- [ ] IRC credentials may transit the trusted relay during initial registration but are never
  retained, persisted, inspected, or logged by the pipe.
- [ ] Logs contain connection record IDs and generations but no IRC message bodies, passwords,
  tokens, cookies, or TLS key material.
- [ ] Report current open, attached, and detached connection counts.
- [ ] Report upstream opens, closes, errors, and IRC timeouts.
- [ ] Report engine attach, detach, and reattach counts and detached durations.
- [ ] Report discarded gap lines and bytes.
- [ ] Report how many distinct connections received discarded traffic in each detach episode and
  the percentage of open connections affected.
- [ ] Report upstream connections lost while the engine was detached. The expected value is zero.
- [ ] Reattachment reports the per-connection gap summary to the engine.
- [ ] Aggregate metrics to avoid unbounded per-connection label cardinality; use redacted structured
  logs with record IDs for individual investigations.
- [ ] Pipe health is independent of gateway and engine health and includes registry and PING-handler
  readiness.

Discarded gap traffic is accepted, but it is not invisible. A few lines on one noisy connection and
traffic discarded across a large percentage of connections must be distinguishable.

## Responsibilities excluded from the pipe

- PostgreSQL, Ecto schemas, migrations, or database authorization.
- Application users, OAuth, sessions, or permissions.
- Message persistence, history, retention, notifications, or Web Push.
- Channel membership persistence, presence, topics, or user lists.
- IRC command policy, slash-command parsing, transcripts, or human-readable formatting.
- Connection remedies, retry decisions, nickname selection, or reconnect scheduling.
- Phoenix, HTTP, websocket, React, PWA, or Oban behavior.
- Hosted IRC server behavior.
- Message replay, durable queues, or a general event bus.
- Multiple pipe replicas, automatic failover, leases, fencing, or per-user placement.
- File-descriptor passing, `TCP_REPAIR`, CRIU, TLS-state transfer, or hot-code upgrades.

## Deployment behavior

### First-party split environment

- [ ] Add a separately built pipe release and separately managed `topics-club-pipe.service`.
- [ ] Give the pipe a stable node name, cookie, and fixed loopback distribution port.
- [ ] Engine deployment and rollback leave the pipe service and upstream sockets running.
- [ ] Gateway deployment and rollback continue to leave both engine and pipe running.
- [ ] Pipe deployment is a separate explicit operation and acknowledges that it reconnects IRC.
- [ ] No iteration is deployed to production while this plan is being developed.

### Combined and simple hosting

- [ ] Preserve the current fast local-development workflow.
- [ ] Preserve combined Railway-like and Docker Compose deployment choices.
- [ ] Do not require simple combined installations to manage three application services.
- [ ] Decide separately whether combined mode keeps the current direct engine transport or runs a
  local pipe application without a separate process-lifetime guarantee.
- [ ] Do not let combined-mode packaging block the `testvps` proof of separate pipe and engine nodes.

## Super-tiny iteration rules

Stages are ordering groups only. Every implementation iteration must:

- Change one behavior or introduce one compatible seam.
- Leave the combined application and existing tests working.
- Leave the split application working in `testvps`.
- Avoid combining a mechanical move, contract change, and behavior change.
- Use expand, switch, and contract as separate iterations.
- Add focused tests for that slice and run `mix precommit`.
- Install only into the resettable `testvps`, never production.
- Exchange two-way traffic with the local synthetic IRC server.
- Record pipe, engine, session, and synthetic IRC connection identity before and after the test.
- Commit only after focused tests, `mix precommit`, and `testvps` all pass.
- Produce one independently revertible commit.

If an iteration needs several unrelated assertions to explain why it is safe, split it again before
implementation.

## Implementation checklist

### Stage 0 — Characterize and freeze contracts

Complexity: **M**. No production behavior changes.

- [ ] Iteration 0.1: prove the current engine owns the upstream transport and stopping it closes the
  synthetic IRC connection.
- [ ] Iteration 0.2: document exact `Ircxd.Client` socket, PING, registration, and connection-info
  ownership points requiring seams.
- [ ] Iteration 0.3: freeze pipe contract fields and generation rules.
- [ ] Iteration 0.4: freeze delivery-failure semantics and the exact moment a gap starts.
- [ ] Iteration 0.5: freeze the minimum engine protocol-state snapshot needed for resume.
- [ ] Iteration 0.6: freeze targeted state reconciliation after a gap.
- [ ] Iteration 0.7: choose combined-mode packaging without changing it yet.

### Stage 1 — Create an inert pipe node

Complexity: **M**. The engine still uses direct sockets.

- [ ] Iteration 1.1: create the minimal pipe OTP application with an empty supervisor.
- [ ] Iteration 1.2: add its independent release definition and artifact-content test.
- [ ] Iteration 1.3: boot the empty pipe as a separate node in `testvps` without changing traffic.
- [ ] Iteration 1.4: add pipe health and zero-connection diagnostics.
- [ ] Iteration 1.5: add static engine-to-pipe connectivity and version negotiation.
- [ ] Iteration 1.6: test pipe-node loss as a degraded engine dependency while direct sockets remain.

### Stage 2 — Add transport primitives

Complexity: **L**. Only one synthetic connection is migrated initially.

- [ ] Iteration 2.1: add the registry and `LIST` for inert test entries.
- [ ] Iteration 2.2: add generations and stale-generation rejection for inert entries.
- [ ] Iteration 2.3: add plain TCP `OPEN` to the synthetic IRC server without attachment.
- [ ] Iteration 2.4: add one explicit generation-matched `CLOSE` path.
- [ ] Iteration 2.5: add TLS ownership and verification in a focused local TLS test.
- [ ] Iteration 2.6: add engine `ATTACH` without live data relay.
- [ ] Iteration 2.7: add engine-to-IRC `SEND` for one line.
- [ ] Iteration 2.8: add IRC-to-engine `DATA` for one line with explicit successful delivery.
- [ ] Iteration 2.9: detach the consumer without closing upstream.
- [ ] Iteration 2.10: reattach the same consumer to the same generation.

### Stage 3 — Move PING and add gap accounting

Complexity: **M**. Still limited to synthetic connections.

- [ ] Iteration 3.1: characterize tagged and untagged current PING/PONG behavior.
- [ ] Iteration 3.2: make the pipe recognize one valid PING and send its PONG.
- [ ] Iteration 3.3: cover tagged and prefixed valid PING forms.
- [ ] Iteration 3.4: prevent the engine transport from producing a duplicate PONG.
- [ ] Iteration 3.5: add engine monitoring and a deterministic attached-to-detached transition.
- [ ] Iteration 3.6: discard and count one non-PING line while detached.
- [ ] Iteration 3.7: add bytes and detached duration to the gap summary.
- [ ] Iteration 3.8: count affected connections and percentage per detach episode.
- [ ] Iteration 3.9: return the gap summary before live relay resumes.
- [ ] Iteration 3.10: prove PING keeps upstream open longer than a normal engine restart interval.

### Stage 4 — Resume one engine connection

Complexity: **XL**. Highest-risk stage; each iteration remains limited to one connection and one
state concern.

- [ ] Iteration 4.1: add an engine transport seam while production still uses direct transport.
- [ ] Iteration 4.2: perform initial registration for one synthetic connection through the pipe.
- [ ] Iteration 4.3: capture and restore only the minimum protocol snapshot frozen in Stage 0.
- [ ] Iteration 4.4: restart engine and attach without sending registration again.
- [ ] Iteration 4.5: restore current nickname correctly.
- [ ] Iteration 4.6: restore capability and ISUPPORT behavior correctly.
- [ ] Iteration 4.7: restore the self-joined channel set without sending JOIN.
- [ ] Iteration 4.8: process a zero-gap reattachment and resume messages.
- [ ] Iteration 4.9: process a non-zero gap and run one targeted reconciliation query.
- [ ] Add one reconciliation concern per iteration until nickname and self-channel state are reliable.
- [ ] Iteration 4.10: reconnect only the unsafe generation when resume validation fails.

### Stage 5 — Reconcile authoritative connections

Complexity: **L**.

- [ ] Iteration 5.1: attach one active database record by `server_connections.id`.
- [ ] Iteration 5.2: open a missing active record through existing pacing.
- [ ] Iteration 5.3: leave a paused record unopened.
- [ ] Iteration 5.4: close one generation whose record is paused.
- [ ] Iteration 5.5: close one generation whose record was deleted.
- [ ] Iteration 5.6: reject a stale generation during send.
- [ ] Iteration 5.7: reject a second simultaneous consumer attachment.
- [ ] Iteration 5.8: reattach several connections without upstream reconnects or JOINs.
- [ ] Increase connection count in separate iterations while measuring resource use and gap traffic.

### Stage 6 — Package and verify only in `testvps`

Complexity: **L**. No production deployment.

- [ ] Iteration 6.1: add the pipe service to `testvps` provisioning.
- [ ] Iteration 6.2: install an independently built pipe release in `testvps`.
- [ ] Iteration 6.3: require a healthy compatible pipe before the `testvps` engine starts.
- [ ] Iteration 6.4: restart gateway and prove all pipe, engine, session, and socket identities remain.
- [ ] Iteration 6.5: restart engine and prove pipe and upstream sockets remain.
- [ ] Iteration 6.6: send traffic during engine downtime and verify gap accounting.
- [ ] Iteration 6.7: prove PING keeps every synthetic connection alive during that gap.
- [ ] Iteration 6.8: roll back engine in `testvps` without restarting pipe.
- [ ] Iteration 6.9: deliberately restart pipe and verify paced engine recovery without IRC flooding.
- [ ] Iteration 6.10: run the local two-way capacity benchmark and record resource use and gaps.

## Complexity guardrails

- Keep existing application behavior in the engine unless moving it is required for attachment or
  resume.
- Do not move persistence, notifications, retention, membership policy, remedies, or UI behavior as
  part of this work.
- Do not add a replay buffer, durable event spool, message broker, or delivery cursor.
- Do not make the pipe query PostgreSQL or understand general IRC state.
- PING/PONG and safe line framing are the pipe's only IRC protocol responsibilities.
- Prefer cohesive transport, registry, attachment, and diagnostics modules over one module per event.
- Do not migrate all connections until one synthetic connection survives repeated engine restarts.
- Do not combine plain TCP, TLS, PING, gap accounting, and resume in one iteration.
- A green compile is insufficient: every behavior change requires local-IRC and `testvps` coverage.

## Final acceptance criteria

- [ ] The pipe is a separate minimal BEAM node and service with no database or product-policy
  dependencies.
- [ ] Its registry maps upstream connections to the correct `server_connections.id` and generation.
- [ ] An engine restart leaves pipe PID, upstream sockets, registration, nickname, and channel
  presence intact.
- [ ] The pipe answers PING while the engine is absent.
- [ ] No traffic is silently discarded while an engine consumer is attached.
- [ ] Gap traffic is counted by lines, bytes, affected connections, and duration.
- [ ] The restarted engine receives the gap summary and resynchronizes without blindly reconnecting
  or joining.
- [ ] A failed resume affects only that connection generation.
- [ ] Gateway and engine iteration/rollback in `testvps` never restart the pipe accidentally.
- [ ] A deliberate pipe restart uses paced recovery and does not flood the local IRC server.
- [ ] Combined development and simple hosting remain usable without the three-service topology.
- [ ] No production deployment occurs until this checklist is complete, reviewed, and approved.
