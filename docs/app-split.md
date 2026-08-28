# Application split plan and implementation checklist

## Status

Proposed architecture with implementation tracking. Checked items are already present in the current codebase; unchecked items are required unless they are explicitly marked optional or deferred.

## Complexity and progress

Overall complexity is **XL** with **high operational risk**. This is a staged architecture migration across process ownership, application dependencies, database compatibility, release assembly, Distributed Erlang, deployment automation, and failure recovery. Logical application boundaries must be enforced inside the monolith before files move; the later umbrella conversion should be a mechanical extraction rather than the point where dependencies are discovered.

Sizing used by this document:

| Size | Meaning |
| --- | --- |
| S | Localized change with a narrow test surface |
| M | Cross-module change contained within one subsystem |
| L | Cross-subsystem change with release or data implications |
| XL | Architectural change requiring staged integration and rollback planning |

### Current baseline

- [x] Combined mode runs as one application and one IRC engine on a single BEAM node.
- [x] Connection intent is durable through `server_connections.desired_state` with `connected` and `paused` values.
- [x] Connect and disconnect persist intent before starting or stopping a session.
- [x] Session startup reloads the authoritative connection and refuses paused connections.
- [x] A Phoenix release Dockerfile builds the combined release from the repository root.
- [x] Production Docker Compose provides one combined application service and one persistent PostgreSQL service.
- [x] `ircxd` is fetched from `HashNuke/ircxd` and pinned by `mix.lock` until it is published on Hex.
- [x] Every current module has a documented logical owner: core, shared protocol, engine, web, combined assembly, or tooling.
- [x] All web-to-IRC calls pass through `Ircpipe.EngineClient`.
- [x] Core and web modules have no direct dependency on engine implementation modules.
- [x] The combined supervision tree is divided into logical core, engine, and web supervisors.
- [ ] The repository is an umbrella containing core, engine, and web OTP applications.
- [ ] The three release artifacts build independently.
- [ ] Split web and engine nodes communicate successfully in an integration environment.
- [ ] First-party bare-host deployment and rollback automation is complete.

### Workstream summary

| Workstream | Size | Risk | Primary difficulty |
| --- | --- | --- | --- |
| 0. Baseline and dependency inventory | M | Medium | Finding hidden runtime coupling before moves begin |
| 1. Logical boundaries and engine contract inside the monolith | XL | High | Enforcing one-way dependencies and replacing direct process calls without changing behavior |
| 2. Mechanical umbrella extraction | M | Medium | Moving already-separated code and tests without changing behavior or losing coverage |
| 3. Release and container packaging | L | High | Producing three minimal, correctly configured artifacts |
| 4. Distributed runtime | XL | Critical | Singleton safety, failure handling, PubSub, and protocol compatibility |
| 5. Hosted `Ircxd.Server` | XL | High | Isolated supervision, authentication, TLS, and server persistence |
| 6. First-party deployment automation | L | High | Atomic deploys, migrations, systemd, health checks, and rollback |
| 7. Verification and operational hardening | L | High | Exercising cross-node failures and N/N-1 compatibility |

The critical path is workstreams 0 through 4, followed by 6 and 7. Workstream 5 can begin after the engine application boundary is stable and does not block the first split deployment.

## Summary

Ircpipe will support two runtime modes from one codebase:

1. **Combined mode** runs the web application and IRC engine on one BEAM node and in one production release. This remains the default for local development, Railway, Docker Compose, and simple personal deployments.
2. **Split mode** runs a small, long-lived IRC engine release separately from the frequently deployed web release. The two releases share PostgreSQL and communicate over Distributed Erlang.

Both modes must use the same engine client API and the same message-ingestion path. Combined mode is not a second implementation: the engine client resolves to a local engine in combined mode and a clustered engine in split mode. Before the repository becomes an umbrella, the monolith will use these same logical component boundaries and adapters so the physical extraction does not require a second architectural rewrite.

The split is intended to avoid restarting IRC client connections and the hosted `Ircxd.Server` when only Phoenix, React, authentication, APIs, or other web-facing behavior changes. It does not require hot code upgrades or release upgrade instructions (`relup`).

## Goals

- Keep outbound IRC sessions alive across ordinary web deployments.
- Keep clients connected to the hosted `Ircxd.Server` across ordinary web deployments.
- Keep the engine release small, stable, and rarely deployed.
- Preserve the existing low-latency message path: persist once, then broadcast immediately after commit.
- Keep the default Docker and Railway deployment as simple as it is today.
- Keep one PostgreSQL database, one canonical Ecto schema history, and one migrations directory.
- Use one application-level interface for IRC operations in both combined and split modes.
- Enforce the future umbrella dependency graph while the code still runs in one OTP application.
- Preserve existing module names during physical extraction unless a name actively misrepresents ownership.
- Continue enforcing exactly one active IRC engine.

## Non-goals

- Hot upgrades or `relup` generation.
- Multiple active engine replicas.
- Per-connection ownership leases or horizontal engine scaling.
- A general-purpose message broker.
- A new internal HTTP API between the web and engine releases.
- Oban in the realtime message-display path.
- A raw IRC-event staging pipeline for ordinary messages.
- Independent databases for the engine and web applications.
- Making every current `Ircpipe.Chat` module part of the engine.

## Target topology

### Combined mode

```text
Browser
   |
   v
+--------------------------------------------------+
| ircpipe release                                  |
|                                                  |
| Phoenix + React + auth + JSON APIs               |
| Engine client -> local engine API                |
| IRC sessions + bouncer + hosted Ircxd.Server     |
| Repo + Vault + PubSub + role-appropriate Oban   |
+-------------------------+------------------------+
                          |
                          v
                     PostgreSQL
```

Combined mode does not require Erlang distribution, an Erlang cookie, engine-node configuration, or a second service.

### Split mode

```text
Browser
   |
   v
+-----------------------------+       Distributed Erlang       +-----------------------------+
| ircpipe_web release         | <-----------------------------> | ircpipe_engine release      |
|                             |                                 |                             |
| Phoenix + React + auth      |                                 | Engine API                  |
| JSON APIs + Channels        |                                 | IRC sessions + bouncer      |
| Engine client               |                                 | Reconnect + autojoin        |
| Discovery channel workers   |                                 | Hosted Ircxd.Server         |
| Repo + Vault + PubSub       |                                 | IRC ingestion + state       |
| Web-owned Oban queues       |                                 | Repo + Vault + PubSub       |
+--------------+--------------+                                 | Engine-owned Oban queues    |
               |                                                +--------------+--------------+
               |                                                               |
               +-------------------------+-------------------------------------+
                                         |
                                         v
                                    PostgreSQL
```

The first split-mode release supports one web node and one engine node. Additional web replicas may be considered separately; the engine remains a singleton until database-backed ownership leases and fencing exist.

## Pre-umbrella logical boundaries

The application must first behave like three cooperating OTP applications while it is still one Mix project and one BEAM node. Physical source paths do not enforce ownership: an Elixir module keeps the same name regardless of which OTP application compiles it. For example, `Ircpipe.Irc.Session` can move from `lib/ircpipe/irc/session.ex` to `apps/ircpipe_engine/lib/ircpipe/irc/session.ex` without changing its module name or its internal callers.

Use the following logical ownership before creating the umbrella:

| Logical component | Current/future namespaces | Allowed dependencies | Future OTP application |
| --- | --- | --- | --- |
| Core/data | `Ircpipe.Repo`, `Ircpipe.Vault`, shared identity/data schemas, migration modules, and persistence primitives | External libraries and other core modules only | `ircpipe_core` |
| Shared protocol/contracts | Versioned request, reply, and event envelopes; pure IRC identifiers, command metadata, and validation needed by more than one role | Standard library, `:telemetry`, and `ircxd`; never Repo, Ecto schemas, or another Ircpipe component | `ircpipe_core` initially; split further only if justified |
| Engine | `Ircpipe.Irc` process ownership, per-user session orchestration, ingestion, hosted server | Core and shared contracts | `ircpipe_engine` |
| Web | `IrcpipeWeb`, browser auth, controllers, Channels, serializers, frontend, directory discovery workers, web-owned jobs | Core, shared contracts, `Ircpipe.EngineClient`, and `ircxd` for discovery | `ircpipe_web` |

The required dependency direction is:

```text
ircpipe_web -------> ircpipe_core <------- ircpipe_engine
      |
      +----> Ircpipe.EngineClient ----> configured adapter
                                           |          |
                                           |          +--> RPC adapter in split mode
                                           +-------------> local adapter in combined mode
```

The local adapter is an engine implementation and may call local sessions, registries, and supervisors. The RPC adapter may address the remote engine API by module and operation name, but it must not require engine implementation code to be included in the web release. Core persistence modules must never call into the engine to complete a database operation; `EngineClient` is the explicit adapter port for operations that require the engine.

This rule requires deliberate untangling before any file move. In particular:

- `IrcpipeWeb` currently calls `Ircpipe.Irc.Session`, `SessionLocator`, `SessionSupervisor`, `Commands`, and `CommandRegistry`; process-owning calls must move behind `EngineClient`, while genuinely pure shared protocol functions must be assigned to the shared boundary.
- `Ircpipe.Chat.Connections` currently reaches into `Ircpipe.Irc.ConnectionLock` and `SessionSupervisor` during state changes and deletion. Persistence primitives must be separated from engine-owned quiescence and orchestration so core never depends on engine internals.
- Pure identifier and casemapping behavior currently under `Ircpipe.Irc.Identifier` is used by chat persistence modules. It may retain its module name during extraction, but its logical ownership and dependency requirements must be shared rather than engine-private.
- `Ircpipe.Discovery.ServerChannelLister` opens a short-lived `Ircxd.Client` to issue `LIST` and is driven by `Ircpipe.Discovery.Refresher`. This remains web-owned directory functionality and is distinct from the engine's long-lived per-user sessions.
- Background jobs must have a single runtime owner. Jobs that manipulate live sessions belong to the engine role even when they use core persistence modules.

The monolith should expose three logical supervisors—core, engine, and web—under the existing root application. Combined mode starts all three. Their child lists, registered names, configuration, and job ownership must already match the future child applications before the umbrella conversion begins.

Boundary enforcement must be automated. Local precommit fails when web code references engine implementation modules, core code references engine or web modules, engine code references web modules, or an unapproved dependency cycle is introduced. The same gate must be added to CI before the workstream exit gate can close. The check operates on compiler/xref information where possible, with a narrow explicit allowlist for temporary migration edges. Every temporary edge needs an owner and removal task.

The authoritative ownership and transition manifest is `config/boundaries.exs`. It currently tracks compiled production files, all 29 migration modules, and test-support files under six owners: the four deployable logical components plus `assembly` for the temporary combined composition root and `tooling` for Mix tasks. `assembly` and `tooling` are not future OTP applications and are excluded from deployable-component cycle analysis. Migration files receive an owner, but Mix does not compile them into the application xref graph; their internal references therefore require migration tests and review rather than xref enforcement.

Run `mix ircpipe.check_boundaries` to validate the manifest against Mix's direct xref graph. The checker fails on unowned or multiply owned files, unknown components, cycles in the permanent allowed-dependency policy, actual deployable cycles outside the explicit transition-cycle baseline, new forbidden file edges, dependency-label escalation, malformed or duplicate exceptions, stale exceptions or transition cycles, and compiled production files missing from xref. `mix precommit` runs this check immediately after warning-free compilation.

The initial graph already has one temporary strongly connected component containing core, engine, and web because the monolith has allowlisted reverse edges in all three components. The checker records that component set explicitly and rejects a different or additional deployable strongly connected component. This baseline must disappear when the reverse edges are removed; it is not a permitted final umbrella topology.

The initial inventory records 36 exact temporary dependency edges:

| Source direction | Count | Required resolution |
| --- | ---: | --- |
| Core to web | 1 | Replace browser-shaped payload construction with a stable internal event boundary |
| Engine to web | 6 | Separate browser events and Web Push enqueueing from engine-owned persistence/effects |
| Web to engine | 29 | Route live operations through `EngineClient` and separate connection/deletion orchestration |

Every exception records its current xref label, responsible logical owner, reason, and removal checkpoint. The initial allowlist is capped at 36 entries, and a removed edge makes its exception stale and fails the check until the manifest is deliberately tightened. Mix xref reports dependencies at file-edge granularity: a second call added between an already-exempt source/target pair is not a new xref edge. Review and focused behavioral tests must therefore police call-site growth within an existing exception, while the automated gate prevents new file pairs and a growing exception count.

## OTP application and release layout

After the pre-umbrella boundary gate passes, convert the repository into an umbrella with these applications:

```text
apps/
  ircpipe_core/
  ircpipe_engine/
  ircpipe_web/
```

### `ircpipe_core`

Stable code needed by both releases:

- `Ircpipe.Repo`
- `Ircpipe.Vault`
- Ecto schemas and encrypted Ecto types
- The canonical migrations directory
- Phoenix PubSub supervision
- Stable internal request, reply, and event envelopes
- `Ircpipe.EngineClient`
- Shared database primitives that do not own web or IRC policy

`ircpipe_core` must not depend on `ircpipe_engine` or `ircpipe_web`.

### `ircpipe_engine`

The small, long-lived connection and ingestion runtime:

- `Ircpipe.Irc.SessionSupervisor` and session registries
- `Ircpipe.Irc.Bouncer`
- `Ircpipe.Irc.Session` and its protocol handlers
- `Ircxd.Client` integration
- Hosted `Ircxd.Server` and its application adapter
- Reconnect and autojoin behavior
- Stable canonical message ingestion
- Connection lifecycle and IRC-derived presence persistence
- Post-commit internal PubSub events
- The engine API and singleton registration
- Jobs that must quiesce or manipulate live IRC sessions

The engine must not depend on Phoenix Endpoint, controllers, browser authentication, HTML, React assets, or frontend event serialization.

### `ircpipe_web`

Frequently changed product and presentation code:

- Phoenix Endpoint, router, controllers, Channels, and authentication
- React and Storybook assets
- Browser-facing REST and realtime payload serialization
- Bootstrap and history queries
- Account, settings, read-state, and notification-preference behavior
- Web Push delivery and other web-owned background jobs
- Directory discovery refresh and its short-lived `Ircxd.Client` channel-list workers
- The web side of `Ircpipe.EngineClient`

The web application must not depend on the local engine adapter. Combined-release configuration may select that adapter because the combined release includes the engine application; the web-only release selects the RPC adapter.

### Releases

Define three releases:

| Release | Applications | Intended use |
| --- | --- | --- |
| `ircpipe` | core + engine + web | Default Docker, Railway, and simple self-hosting; development uses the same combined supervision tree under Mix |
| `ircpipe_web` | core + web | Frequently deployed web tier in split mode |
| `ircpipe_engine` | core + engine | Small long-lived engine in split mode |

`ircxd` is a shared library dependency, not an ownership boundary. The engine uses it for long-lived outbound sessions and the hosted server; the web role uses it for short-lived directory channel-list workers; shared protocol primitives also use its casemapping and validation types. Both split releases therefore include `ircxd`, while only the engine release starts the user-session and hosted-server supervision trees. Until `ircxd` is published on Hex, builds fetch it from the `HashNuke/ircxd` GitHub repository rather than relying on a sibling checkout.

## Engine boundary

The engine is more than a socket holder, but less than a second web backend. It owns the stable work required to accept IRC traffic durably and keep protocol state coherent.

### Engine-owned behavior

- Opening, supervising, reconnecting, and closing IRC connections.
- Resolving live connection status from the session process.
- Sending IRC commands and correlating replies.
- Persisting inbound and accepted outbound messages.
- Updating IRC-derived connection status, channel membership status, presence, nickname, casemapping, and server information.
- Updating unread and mention counters in the same transaction as message insertion.
- Creating notification records when ingestion determines a message is eligible.
- Broadcasting stable internal events only after the database transaction commits.
- Restoring recent sessions whose durable desired state is `connected`, plus their persisted autojoins, after an engine restart.

### Web-owned behavior

- Authenticating and authorizing the browser request before invoking the engine client.
- Formatting public REST and Phoenix Channel payloads.
- Rendering pending, successful, and failed sends.
- Reading message history and rebuilding current UI state after reconnect.
- Marking buffers read and managing user-facing preferences.
- Delivering Web Push jobs created from committed notification records.
- All visual and interaction behavior.

### Shared data, separate contexts

Both releases use the same Ecto schemas, but behavior modules should reflect ownership. Engine ingestion modules should not call web modules, and web contexts should not access local engine registries or supervisors.

The current `Ircpipe.Chat` namespace may be separated gradually during monolith demarcation. Moving a schema into `ircpipe_core` does not require moving every context that uses that schema into the core application. By the time physical extraction begins, each context must already depend only on public APIs owned by its declared logical component.

### Desired state versus observed status

`server_connections.desired_state` is the durable user intent and is constrained to `connected` or `paused`. It defaults to `connected`, including for rows that predate the column, so existing deployments retain their current reconnect behavior.

`server_connections.status` remains observed runtime state such as `connecting`, `connected`, `disconnected`, or `errored`. Runtime events may update `status`, but they must never overwrite `desired_state` or use a stale status value to decide whether a connection should return after an engine restart.

The ordering for user actions is intentional:

- Disconnect persists `desired_state = 'paused'` before stopping the session. If stopping is interrupted, later reconciliation still knows not to restore it.
- Connect persists `desired_state = 'connected'` before starting the session. If startup fails, the engine retains the intention and can retry or report the observed error.
- Explicit actions that inherently require a connection, such as joining a channel or topic, also change the desired state to `connected`.
- Passive engine startup and browser bootstrap only start sessions whose desired state is `connected`.

Session startup re-reads the authoritative row and refuses a paused connection, preventing stale callers from bypassing the intent check. In split mode these mutations and the associated process action move behind `Ircpipe.EngineClient`; the web release must not independently update intent and assume the engine acted on it.

## Realtime message path

Oban and polling are not part of normal message display.

```text
1. Ircxd.Client delivers an IRC event to the engine session.
2. The engine opens one Ecto transaction.
3. The engine inserts the canonical message and updates associated counters/state.
4. The transaction commits.
5. The engine broadcasts a stable internal event through Ircpipe.PubSub.
6. Phoenix PubSub carries the event locally or to the clustered web node.
7. IrcpipeWeb.UserChannel converts it to the browser protocol and pushes it.
```

This retains the current durability rule: the browser is notified only after the canonical record commits. Split mode adds only Distributed Erlang delivery between PubSub nodes.

When the web node is unavailable, the PubSub event may be missed, but the canonical message and current IRC-derived state remain in PostgreSQL. Browser reconnect performs the existing bootstrap/history reconciliation. A durable raw-event journal is not required for this first split.

Slow or retryable work remains asynchronous:

- Web Push delivery
- Cleanup and retention reconciliation
- Connection-deletion reconciliation
- Other tasks that do not gate displaying an ordinary message

## Internal cluster protocol

### Engine discovery

The engine starts a lightweight marker registered under a stable global name. The registration identifies the single engine node; it must not perform all IRC work in one serialized GenServer loop.

In split mode, the RPC adapter resolves the marker, obtains its node, and invokes a stable engine API on that node. The combined-mode local adapter invokes the API under the local engine task supervisor without consulting the marker.

The existing `Ircpipe.Irc.SingleNodeGuard` must be replaced. The new guard permits web nodes in the cluster and fails engine startup when another engine marker is already registered.

This global registration is a singleton guard for the supported static two-node topology, not a substitute for database-backed fencing. Network-partition-safe engine failover remains deferred.

### Request contract

Cluster requests use a versioned envelope and plain terms:

```elixir
%{
  version: 1,
  operation: :send_channel_message,
  request_id: "uuid",
  user_id: 123,
  connection_id: 456,
  payload: %{membership_id: 789, kind: "message", body: "hello"}
}
```

The engine API reloads authoritative records from PostgreSQL and verifies that the connection still belongs to the supplied user. Browser authorization at the web boundary is necessary but not sufficient.

Do not send these values across the cluster boundary:

- Ecto structs or changesets
- PIDs other than the engine marker used for node discovery
- Anonymous functions
- Exceptions as public error contracts
- Engine-internal ircxd structs

Replies use versioned plain maps and stable error atoms. Unknown request versions or operations return explicit unsupported errors rather than crashing the engine.

The checked-in version 1 contract currently defines these operations and expectations:

| Operation | Default timeout | Retry classification |
| --- | ---: | --- |
| Batch connection status | 5 seconds | Safe |
| Connection info | 5 seconds | Safe |
| Ensure/start connection | 15 seconds | Safe |
| Disconnect connection | 10 seconds | Safe |
| Delete connection | 30 seconds | Unsafe |
| Request channel join | 15 seconds | Safe |
| Part channel | 10 seconds | Unsafe |
| Send channel message/action | 10 seconds | Unsafe |
| Send direct message | 10 seconds | Unsafe |
| Execute validated command line | 15 seconds | Unsafe |
| Fetch live channel list | 12 seconds | Safe |

“Safe” means the operation is designed to tolerate a retry after an unavailable/timeout result; callers still use bounded attempts and the same request ID. Message, command, and part operations are unsafe because an ambiguous timeout can follow successful IRC transmission or persistence. The client does not retry automatically in this phase—it exposes the classification in telemetry for the later RPC policy.

`Ircpipe.EngineClient` builds and validates envelopes, invokes the configured adapter dynamically, validates the versioned reply, and returns plain success data or a stable error map. Combined mode selects the engine-owned local adapter without any split-mode environment variables. The web-owned RPC adapter resolves the global engine marker and calls the engine API using a runtime-resolved module name, so it has no compile-time dependency on engine implementation modules.

The engine API reloads the user, connection, membership, or direct-message thread needed by each operation and rechecks ownership before touching a local session. Per-connection API requests take an engine-owned orchestration lock around authorization, durable intent mutation, and the complete process effect. That lock is deliberately distinct from the session subsystem's connection lock, so opposing lifecycle requests are linearized without deadlocking session startup or shutdown. Ecto schemas, `Ircxd.Client.Info`, `MapSet` values, and timestamps are converted to plain maps, lists, and ISO 8601 strings before a reply crosses the adapter boundary. Local requests execute under an engine-owned task supervisor so the same per-operation timeout applies in combined mode without routing all work through the marker process.

### Initial operations

The first version of the engine API must cover every current direct web-to-engine call:

- Batch connection status
- Current connection info needed by shared IRC validation
- Ensure/start connection
- Disconnect connection
- Delete connection, including engine-owned quiescence
- Request channel join
- Part channel
- Send channel message or action
- Send direct message
- Execute and revalidate a plain IRC command line inside the engine
- Fetch the live server channel list

`Ircpipe.EngineClient` maps node-down, timeout, and engine-not-started failures into stable application errors such as `:engine_unavailable` and `:not_connected`.

### Internal event contract

Engine-to-web PubSub events also use versioned plain maps. They represent committed application facts such as:

- Message committed
- Buffer joined or left
- Connection status changed
- Presence synchronized or changed
- Direct-message thread changed
- Notification committed

Browser payload formatting remains in `ircpipe_web`. Internal events must contain enough IDs and committed values for the web node to format the event without consulting engine process state.

Synchronous command execution results remain in the versioned `EngineClient` reply. Command transcript rows and later status changes are canonical messages and therefore use `message_committed`; emitting a second command-result event would duplicate the request reply and the persisted message event without adding recoverable state.

During monolith demarcation, `Ircpipe.InternalEvents` synchronously invokes one configured adapter. The combined configuration selects a web-owned adapter that translates committed internal facts into the existing Phoenix PubSub payloads and Web Push jobs. This is deliberately a small port, not a general event-bus framework. Workstream 4 will supply the split transport adapter that carries the same envelopes between nodes; event producers and browser serializers must not change for that transport move.

## PostgreSQL and migrations

- Both nodes connect to the same PostgreSQL database with independent Repo pools.
- There is one canonical migrations directory under `ircpipe_core`.
- Only the combined release or a dedicated web/migrator invocation runs migrations.
- The engine container never runs migrations automatically.
- Production deployment runs migrations once before starting code that requires them.

Because the engine may intentionally remain on an older release, migrations follow expand-and-contract deployment:

1. Add new tables or nullable/defaulted columns.
2. Deploy code capable of using the additive schema.
3. Backfill when necessary.
4. Upgrade all consumers that use the affected data.
5. Drop or rename old fields only in a later coordinated release.

Web-only schema additions must not force an engine deployment. A destructive change to a table or column used by the engine requires a coordinated engine upgrade.

IRC server credentials remain encrypted at rest. Both combined mode and the engine release require `IRC_CREDENTIALS_KEY`; the web-only release should eventually avoid loading or decrypting secret fields when it only needs public connection data.

## PubSub behavior

All participating nodes start `Ircpipe.PubSub` with the default Distributed Erlang adapter and an explicitly identical pool configuration. Do not derive pool size from the node's CPU count because the web and engine machines may differ.

The initial deployment uses a fixed `pool_size: 1` on every node. A future pool-size change must follow Phoenix PubSub's compatible rolling migration procedure.

Combined mode uses the same PubSub calls locally. Engine modules must not branch between local and clustered publishing.

## Oban ownership

Oban configuration is release-specific even though all jobs use the same PostgreSQL tables:

- Combined release executes all configured queues and required plugins.
- Web release executes notification delivery and other web-owned queues.
- Engine release executes connection-deletion and other jobs that require local access to live IRC sessions.
- Cron entries run only in the release that owns the corresponding work.

Engine ingestion may insert a notification job into an Oban queue that the web release executes. Queue insertion and queue execution are separate responsibilities.

No queue may be enabled on a node where its worker assumes a local IRC registry unless the worker has first been refactored through `Ircpipe.EngineClient`.

The combined monolith now runs two named Oban instances so queue execution already follows the future release boundary:

| Instance owner | Queue/plugin | Workers or purpose |
| --- | --- | --- |
| Engine | `connection_deletions` queue | `ConnectionDeletionWorker`, `ConnectionDeletionEventsWorker`, and `ConnectionDeletionReconcilerWorker` |
| Engine | Cron | Enqueues `ConnectionDeletionReconcilerWorker` once per minute |
| Web | `notifications` queue | `PushWorker` |
| Web | `Oban.Plugins.Pruner` | Prunes the shared jobs table exactly once in combined mode |

Core owns no Oban instance. Job insertion names the intended runtime instance explicitly; therefore a combined node cannot accidentally dispatch a job through an unowned default Oban process.

## Supervision

### Core supervision

Each node starts its own core infrastructure:

- Vault
- Repo
- Phoenix PubSub

The combined monolith starts these once under `Ircpipe.CoreSupervisor` before either role-specific branch.

### Engine supervision

The monolith currently uses this engine branch:

```text
Ircpipe.EngineSupervisor (:one_for_one)
  Engine.Marker (global singleton identity only)
  Engine.OperationLock (per-connection API orchestration)
  Engine.RequestTaskSupervisor
  Ircpipe.EngineOban
  Ircpipe.Irc.SessionSystemSupervisor (:one_for_all)
    SingleNodeGuard
    ConnectionOperationLock
    ClientRegistry
    SessionRegistry
    SessionSupervisor
    Bouncer
```

The future hosted server supervisor will also be a sibling of `SessionSystemSupervisor`. `Ircxd.Server` must not be placed inside the outbound session subsystem's current `:one_for_all` boundary. A hosted-server failure must not restart every outbound client session, and an outbound registry failure must not terminate all hosted IRC clients.

### Web supervision

The monolith currently starts `IrcpipeWeb.Telemetry`, a web-owned engine-restore task supervisor and coalescing restore coordinator, the named web Oban instance, optional `Ircpipe.Discovery.Refresher`, and then `IrcpipeWeb.Endpoint` under `IrcpipeWeb.Supervisor`. Endpoint remains the final web child. Bootstrap schedules desired-session restoration off the response path through the coordinator. It deduplicates the same user/connection across overlapping bootstrap requests and enforces one web-wide limit of eight concurrent engine restoration requests. The web release starts the same branch after Repo, PubSub, and the engine client monitor are available. Engine unavailability must put IRC mutations into a clear degraded state; it must not prevent the web application from serving login, settings, or persisted history.

## Deployment experience

### Default Docker and Railway experience

The default remains one application service plus PostgreSQL:

```text
app (combined ircpipe release)
postgres
```

Requirements:

- Existing Docker and Railway users do not set a deployment-mode variable.
- Existing `mix setup` and `mix phx.server` development workflows remain available.
- The default Dockerfile produces the combined `ircpipe` release.
- `docker-compose.prod.yml` keeps one application service and one PostgreSQL service.
- The combined startup command may continue to run migrations before starting the application.
- No Erlang node name, cookie, clustering hostname, or second health check is required.
- The README presents combined mode first and describes split mode as an advanced production option.

Railway and similar platforms can continue replacing the single combined service normally. The platform runs `/app/bin/migrate` as a pre-deploy command and `/app/bin/server` as the application command. Such a replacement reconnects IRC sessions, which is an accepted tradeoff for the simple deployment mode.

### Self-hosted VPS Compose experience

`docker-compose.prod.yml` is the supported self-hosted VPS package. It contains:

- One combined `ircpipe` application service.
- One PostgreSQL service that is not exposed publicly.
- Persistent PostgreSQL storage chosen explicitly by the operator.
- A database health check before the application starts.
- A migration command before the combined application starts.
- Exactly one application replica.
- An application port intended to sit behind an operator-managed HTTPS reverse proxy.

Self-hosters do not need Erlang distribution, node names, an Erlang cookie, or the operational complexity of split mode.

### First-party split production experience

The topics.club production deployment uses bare OTP releases built from source on the destination host. It does not use Compose to manage the web and engine processes.

- One shared PostgreSQL database is managed separately from the application releases.
- The destination fetches and checks out an exact Git commit rather than deploying an unrecorded moving branch state.
- Production dependencies and assets are built on the destination host with pinned Erlang, Elixir, Node.js, and npm versions.
- `ircpipe_web` and `ircpipe_engine` are assembled into separate versioned directories.
- Stable `current` symlinks select the active web and engine release directories.
- Separate systemd units run web and engine under a dedicated unprivileged account.
- The new web release runs migrations once before its symlink is activated.
- Ordinary web deployments restart only `ircpipe_web`; the engine and its IRC sessions remain running.
- Engine deployments are explicit maintenance operations and reconnect IRC sessions.
- Rollback repoints the affected symlink to a compatible previous release and restarts that service.

The two releases use stable long node names, a shared high-entropy Erlang cookie, static engine-node configuration, fixed distribution ports, and a private network path. Public HTTP is served only by the web release. Hosted IRC ports are served only by the engine release when enabled.

### Optional split Compose harness

An additional `docker-compose.split.yml` may be added as a development and CI integration harness. It is not the primary first-party deployment mechanism. If provided, it has one PostgreSQL service, one engine service, one web service, a one-shot migrator, private distribution networking, and no migration command on the engine.

The web node attempts a static connection to the configured engine node. DNS-based automatic clustering and horizontal engine discovery are outside the first implementation.

Distribution ports and EPMD must not be exposed publicly. A shared Erlang cookie grants powerful access to the cluster; use a high-entropy secret, private networking, and TLS distribution when the nodes communicate across an untrusted network.

## Configuration contract

Combined mode should work with the existing required environment variables. Split mode adds explicit cluster configuration, with names to be finalized during implementation:

```text
RELEASE_NODE=ircpipe_web@web.internal
RELEASE_COOKIE=<high-entropy-cookie>
IRCPIPE_ENGINE_NODE=ircpipe_engine@engine.internal
```

The engine uses its own `RELEASE_NODE` and the same cookie. Secrets should be injected independently into each release; the web release should not receive engine-only secrets unless it genuinely needs them.

Compile-time and runtime configuration must not make the combined release depend on split-mode variables.

## Implementation checklist

Complete workstreams in order unless a task explicitly says it can proceed independently. A workstream is complete only when all of its exit-gate items are checked.

### Workstream 0: Baseline and dependency inventory

Size: **M**. Risk: **Medium**. This prevents hidden coupling from being discovered only after logical demarcation or the later umbrella move begins.

#### Runtime and code inventory

- [ ] List every `IrcpipeWeb` call to `Session`, `SessionLocator`, `SessionSupervisor`, registries, and IRC process names.
- [ ] List every non-web context or worker that assumes an IRC process is local.
- [ ] Trace connect, disconnect, join, part, send, command, channel-list, and deletion flows from public entry point to session process.
- [ ] Trace inbound message, presence, membership, command-result, and connection-status flows from IRC event through commit and PubSub.
- [ ] Inventory every PubSub topic and payload currently consumed by `IrcpipeWeb.UserChannel`.
- [x] Inventory every Oban queue, plugin, cron entry, and worker, and assign each one to core, web, or engine.
- [ ] Inventory all schemas and context modules and record their intended owning application.
- [ ] Inventory compile-time and runtime configuration and classify it as shared, web-only, engine-only, or combined-only.
- [ ] Inventory production secrets and identify which release genuinely requires each secret.
- [ ] Inventory supervision children, restart strategies, registries, and globally or locally registered names.
- [ ] Record the current browser REST and Channel payloads that must remain compatible.
- [ ] Record the current release, migration, Docker, Compose, and service startup behavior.

#### Baseline verification

- [x] Run the current `mix precommit` suite successfully before structural changes.
- [x] Build the current combined Docker image from the repository root.
- [x] Validate the current production Compose configuration.
- [ ] Add or preserve fixtures that exercise every engine operation before routing changes begin.
- [ ] Add regression coverage for commit-before-broadcast behavior where it is not already explicit.
- [ ] Add regression coverage for paused connections surviving bootstrap and process restarts.
- [ ] Decide and document the supported engine protocol compatibility window; initial target is web N with engine N-1.

#### Exit gate

- [ ] Every direct web-to-IRC dependency has an owner and a planned replacement operation.
- [ ] Every background job has exactly one intended execution role.
- [ ] Every current public browser payload has a regression test or deterministic fixture.
- [ ] The combined baseline is green before workstream 1 begins.

### Workstream 1: Demarcate logical applications and introduce the engine boundary inside the monolith

Size: **XL**. Risk: **High**. This is the largest behavior-preserving refactor. It must land and pass its boundary gate before the umbrella exists; no task in workstream 2 is allowed to compensate for an unresolved dependency edge.

#### Declare module and runtime ownership

- [x] Create a checked-in ownership manifest covering every production module and assigning it to core, shared protocol/contracts, engine, web, assembly, or tooling.
- [x] Assign every test-support module and fixture to the component whose public behavior it supports.
- [ ] Classify every external dependency by the logical component that uses it.
- [ ] Classify every application environment key by logical owner and compile-time versus runtime use.
- [ ] Classify every registered process name, Registry, supervisor, and PubSub name by logical owner.
- [ ] Mark the intended future source and test destination for each current directory.
- [ ] Preserve existing module names when moving them later unless a rename is independently justified and tested.
- [x] Record every temporary cross-boundary edge in a narrow allowlist with an owner and removal checklist item.
- [x] Document the allowed dependency graph in contributor guidance.

#### Extract shared protocol primitives from engine internals

- [x] Identify the current pure IRC identifier, command metadata, and validation code needed by more than one component.
- [x] Assign those current pure modules to the shared boundary even when their existing module name begins with `Ircpipe.Irc`.
- [ ] Keep PIDs, process names, Registry lookups, supervisors, sockets, and `ircxd` runtime structs out of shared contracts.
- [x] Treat `ircxd` as an allowed shared library dependency while keeping all Ircpipe process ownership explicit.
- [ ] Document which core, engine, and web modules directly use `ircxd` so each child application declares its actual dependency.
- [ ] Add focused tests proving shared protocol modules run without engine supervision.

#### Enforce dependency direction in the monolith

- [x] Add an automated boundary check based on Mix's direct xref graph.
- [x] Reject new `IrcpipeWeb` references to engine implementation modules outside the exact migration allowlist.
- [x] Reject new core references to engine or web implementation modules outside the exact migration allowlist.
- [x] Reject new engine references to web modules outside the exact migration allowlist.
- [x] Reject cycles in the permanent dependency policy and actual deployable cycles outside the explicit transition-cycle baseline.
- [x] Keep the migration allowlist explicit, file-exact, label-sensitive, capped at the initial 36 edges, and free of namespace-wide exceptions.
- [ ] Add the boundary gate to CI and enforce that exception, budget, and transition-cycle baseline changes only shrink against the base branch.
- [x] Run the boundary check from `mix precommit`.

#### Versioned request and reply contracts

- [x] Define the version 1 request envelope using plain maps and scalar IDs.
- [x] Define stable reply envelopes for successful operations.
- [x] Define stable error atoms for unavailable, timeout, unauthorized, not-connected, invalid-state, unsupported-version, and unsupported-operation failures.
- [x] Validate required request fields before dispatch.
- [x] Reject unknown versions and operations without crashing the engine API.
- [x] Prevent Ecto structs, changesets, PIDs, functions, exceptions, and `ircxd` structs from becoming public contract values.
- [x] Generate or validate request IDs for logging and correlation.
- [x] Define per-operation timeout expectations.
- [x] Define which operations are safe to retry and which require idempotency protection.
- [x] Add contract tests for valid and invalid requests, replies, and errors.

#### Engine API and client

- [x] Add the engine API module that accepts versioned requests and reloads authoritative database records.
- [x] Reauthorize every operation using `user_id` and `connection_id` inside the engine API.
- [x] Add an engine marker process without serializing all operations through that process.
- [x] Add `Ircpipe.EngineClient` as the only application-facing IRC operations interface.
- [x] Add the combined-mode local adapter.
- [x] Treat the local adapter as engine-owned implementation code rather than core or web code.
- [x] Define the RPC adapter module boundary without adding a compile-time dependency on engine implementation modules.
- [x] Configure the adapter without requiring split-mode environment variables in combined mode.
- [x] Normalize exits, missing processes, and session failures into stable client errors.
- [x] Add telemetry around operation name, duration, result, timeout, and request ID.
- [x] Add local adapter tests that exercise the same request envelopes intended for split mode.

#### Route all operations through `EngineClient`

Checkpoint 4 routing is implemented and passed its GPT-5.6 Sol xhigh checkpoint review. Live REST operations other than deletion quiescence, bootstrap restoration/status, and Phoenix Channel operations now use `EngineClient`; live-status formatting uses the batch status operation, send-failure persistence occurs inside the engine API, and bootstrap presence reads use a core-owned query module. No module under `IrcpipeWeb` directly references an engine implementation module. The temporary dependency budget has fallen from 36 to 14; the remaining context/deletion and engine-to-web edges belong to checkpoint 5. The reviewed checkpoint passed `mix precommit` with 680 Elixir tests, 227 frontend tests, the Storybook build, and the boundary gate.

Checkpoint 5 is in progress. Connection deletion now enters the engine through a versioned `delete_connection` operation, and the engine-owned `Ircpipe.Chat.ConnectionDeletion` module owns quiescence, durable recovery, final deletion, and deletion-event dispatch. The web connection facade no longer constructs deletion jobs, mutates durable connection intent, or calls engine locks and session supervision. Durable deletion workers acquire the engine operation lock before resuming. Web connection snapshots are now query-only; casemapping reconciliation stays in engine registration and join paths.

The stable event slice now emits versioned plain-map facts after commit for messages, notifications, connection status, buffer lifecycle, presence, and direct-message-thread lifecycle. A small configured publisher port hands those facts to web-owned realtime and notification handlers in combined mode; engine and core modules no longer construct browser events or enqueue web jobs. The boundary graph now contains 236 owned files and 746 checked project edges, with no temporary dependency exceptions or deployable-component cycles. An expanded set of 252 chat, notification, session, Channel, and event-contract tests passes. The existing React reconnect/bootstrap reconciliation suite also passes all 98 tests, including cursor catch-up after socket loss, IRC server reconnect, malformed reconnect state, and missed command-status repair.

- [x] Route batch live-status lookup through the client.
- [x] Route ensure/start connection through the client.
- [x] Route disconnect/stop connection through the client.
- [x] Route connection deletion through the client while keeping quiescence internal to deletion orchestration.
- [x] Route channel join and topic join through the client.
- [x] Route channel part through the client.
- [x] Route channel messages and actions through the client.
- [x] Route direct messages through the client.
- [x] Route command lines through the client and re-resolve and revalidate their intent inside the engine API.
- [x] Route live server channel-list requests through the client.
- [x] Keep directory discovery's short-lived `ircxd` clients separate from per-user engine sessions and explicitly web-owned.
- [x] Remove session locator and registry lookups from REST payload formatting.
- [x] Remove session locator and registry lookups from Channel payload formatting.
- [x] Refactor deletion workers so they execute in the engine role rather than assuming a local session registry from web code.
- [x] Make web connection snapshots query-only and keep membership reconciliation in engine-owned registration and join paths.
- [x] Refactor any remaining context functions that combine database writes with direct local process actions.
- [x] Split `Ircpipe.Chat.Connections` persistence primitives from engine-owned connection quiescence and deletion orchestration.
- [x] Remove `Ircpipe.Chat.Connections` calls to `Ircpipe.Irc.ConnectionLock` and `SessionSupervisor`.
- [x] Ensure live-session deletion jobs execute only in the engine role while calling persistence APIs owned below the engine boundary.

#### Demarcate supervision before extraction

- [x] Add a logical core supervisor for Vault, Repo, shared PubSub, and role-neutral infrastructure.
- [x] Add a logical engine supervisor for the single-node guard, operation lock, registries, session supervisor, bouncer, and later hosted server.
- [x] Add a logical web supervisor for telemetry, directory discovery refresh, Endpoint, and web-owned runtime processes.
- [x] Make the existing root application start core, engine, and web supervisors in combined mode.
- [x] Assign every Oban queue and plugin to one logical runtime role before changing release layout.
- [x] Ensure shared infrastructure starts exactly once in combined mode.
- [x] Preserve Endpoint-last ordering in the logical web supervisor.
- [x] Preserve Endpoint configuration-change handling through the root application during this phase.
- [x] Add combined-mode supervision tests that assert the expected logical supervisor branches and critical children.

#### Preserve durable connection intent

- [x] Store `desired_state` as constrained durable data.
- [x] Persist `paused` before stopping a connection.
- [x] Persist `connected` before starting a connection.
- [x] Re-read the authoritative connection during session startup and reject paused connections.
- [ ] Move desired-state mutation and the corresponding process action behind one engine client operation.
- [ ] Ensure join/topic operations deliberately set desired state to connected before requiring a session.
- [ ] Define retry behavior when intent persists successfully but the process action fails.
- [ ] Restore recent desired-connected sessions and persisted autojoins after engine startup.
- [ ] Prove that passive browser bootstrap never changes paused intent.

#### Stable internal event contract

- [x] Define a versioned internal event envelope with event ID, type, occurred-at value, and committed IDs/data.
- [x] Define message-committed events.
- [x] Define connection-status events.
- [x] Define buffer joined and left events.
- [x] Define presence synchronized and changed events.
- [x] Define direct-message-thread events.
- [x] Keep synchronous command results in versioned `EngineClient` replies and publish committed command transcript updates through `message_committed`, avoiding a duplicate event path.
- [x] Publish only after the transaction containing the canonical data commits.
- [x] Keep browser-specific field names and formatting out of engine events.
- [x] Convert internal events to the existing REST/Channel protocol in the web layer.
- [x] Preserve browser payload compatibility with deterministic tests.
- [x] Verify browser history reconciliation recovers events missed while the web layer is unavailable.

#### Combined-mode exit gate

- [x] Every production module and runtime child has exactly one logical owner.
- [x] The temporary dependency-edge allowlist is empty.
- [x] Automated boundary checks pass with the intended core <- web and core <- engine dependency direction.
- [x] No module under `IrcpipeWeb` calls an IRC session, locator, registry, or supervisor directly.
- [x] No core module calls an engine process, Registry, supervisor, or adapter implementation directly except through the configured `EngineClient` adapter contract.
- [x] No engine module references `IrcpipeWeb`.
- [x] No web-owned worker assumes an IRC process is local.
- [x] Every engine operation uses the versioned request path in combined mode.
- [x] The root application starts distinct logical core, engine, and web supervisor branches.
- [ ] The ownership manifest maps cleanly to future `apps/ircpipe_core`, `apps/ircpipe_engine`, and `apps/ircpipe_web` destinations.
- [ ] Existing controller, Channel, IRC, retention, presence, and notification tests remain green.
- [ ] Ordinary messages still commit before broadcast and do not pass through Oban.
- [ ] The browser protocol remains compatible.
- [ ] `mix precommit` and a combined release smoke test pass.
- [ ] Record the complete test count and per-component counts so the umbrella move cannot silently lose test discovery.

### Workstream 2: Mechanically extract the logical components into three OTP applications

Size: **M**. Risk: **Medium** after the workstream 1 exit gate passes. This workstream changes physical ownership and Mix configuration, not architecture or product behavior. If a move reveals a new dependency design problem, stop and resolve it in the monolith boundary model instead of adding a shortcut between child applications.

#### Extraction rules

- [ ] Do not begin the umbrella conversion until every workstream 1 exit-gate item passes.
- [ ] Keep production module names unchanged during physical moves.
- [ ] Move source modules and their focused tests as one coherent component slice.
- [ ] Keep cross-component integration tests at the umbrella root or assign them an explicit owning application.
- [ ] Make one ownership move at a time and run its focused tests before the next move.
- [ ] Run the root boundary check after every component move.
- [ ] Run root `mix precommit` after every completed ownership slice.
- [ ] Compare discovered test counts with the recorded monolith baseline after every test-path change.
- [ ] Do not introduce temporary child-application dependency cycles to make an intermediate move compile.
- [ ] Do not combine module renaming or behavior changes with filesystem extraction.

#### Umbrella scaffolding

- [ ] Create an umbrella root project with shared aliases and build paths.
- [ ] Create `apps/ircpipe_core`.
- [ ] Create `apps/ircpipe_engine`.
- [ ] Create `apps/ircpipe_web`.
- [ ] Preserve the existing `Ircpipe` and `IrcpipeWeb` module namespaces where renaming adds no value.
- [ ] Move frontend assets and Storybook under the web application while preserving existing npm commands.
- [ ] Update formatter inputs for the umbrella and all child applications.
- [ ] Update test support paths and shared fixtures without introducing cross-application test coupling.
- [ ] Update `mix setup`, asset, test, and `mix precommit` aliases at the umbrella root.
- [ ] Prove root `mix test` discovers all previously recorded tests before moving the next component.

#### Core ownership

- [ ] Move `Ircpipe.Repo` into core.
- [ ] Move `Ircpipe.Vault` and encrypted Ecto types into core.
- [ ] Move all shared Ecto schemas into core.
- [ ] Move the canonical migrations directory into core and update repository migration paths.
- [ ] Move PubSub naming and shared PubSub configuration into core.
- [ ] Move versioned engine request, reply, and event definitions into core.
- [ ] Move shared account identity needed to authorize engine requests into core.
- [ ] Move database primitives needed by both roles into core without moving web or IRC policy indiscriminately.
- [ ] Keep core free of dependencies on engine and web applications.

#### Engine ownership

- [ ] Move outbound session supervision, registries, session modules, and protocol handlers into engine.
- [ ] Move `Ircpipe.Irc.Bouncer` into engine.
- [ ] Declare `ircxd` in engine for long-lived outbound sessions and hosted-server integration.
- [ ] Move connection restoration and autojoin logic into engine.
- [ ] Move canonical IRC message ingestion and IRC-derived state updates into engine.
- [ ] Move engine-owned Oban workers into engine.
- [ ] Add the isolated hosted-server supervisor branch even if the hosted server remains disabled initially.
- [ ] Keep engine free of Phoenix Endpoint, controllers, HTML, authentication UI, React, and browser serialization.

#### Web ownership

- [ ] Move Endpoint, router, controllers, Channels, socket, authentication, HTML, and mailer into web.
- [ ] Move React, CSS, service worker, and Storybook assets into web.
- [ ] Keep browser payload serializers in web.
- [ ] Keep bootstrap, history, read-state, settings, and notification-preference behavior in web.
- [ ] Keep Web Push delivery and other web-owned Oban workers in web.
- [ ] Move directory discovery refresh and `ServerChannelLister` into web and declare its direct `ircxd` dependency.
- [ ] Configure the web side of `EngineClient` without a compile-time dependency on engine implementation modules.

#### Dependency and supervision enforcement

- [ ] Give each child application only the Hex/Git dependencies it uses.
- [ ] Translate the already-green logical dependency graph into child `deps/0` declarations without adding new edges.
- [ ] Make web compile without engine implementation modules while retaining `ircxd` for directory discovery.
- [ ] Make engine compile without Phoenix Endpoint and frontend dependencies.
- [ ] Check compile-connected dependency graphs for accidental cycles.
- [ ] Start Vault, Repo, and PubSub exactly once per node.
- [ ] Start engine supervision only in combined and engine releases.
- [ ] Start Endpoint only in combined and web releases.
- [ ] Start release-owned Oban queues only after Repo is available.
- [ ] Start Endpoint last in the web supervision tree.
- [ ] Preserve configuration-change handling for Endpoint in the web application.

#### Umbrella exit gate

- [ ] No production module was renamed solely because its file moved into a child application.
- [ ] No product behavior or public payload changed as part of the extraction.
- [ ] Each child application compiles and tests independently where practical.
- [ ] The web application contains no engine implementation modules or long-lived user-session ownership.
- [ ] The engine application contains no Endpoint, router, controller, HEEx, or React assets.
- [ ] The combined supervision tree starts shared infrastructure once.
- [ ] The combined application behaves the same as before the umbrella conversion.
- [ ] Root and per-component test counts match the recorded pre-umbrella expectations.
- [ ] The boundary checker passes without new exceptions or child-application dependency cycles.
- [ ] Root `mix precommit` passes.

### Workstream 3: Build release and container artifacts

Size: **L**. Risk: **High**. The artifacts must be minimal and role-correct; a release that merely boots is not sufficient.

#### Release definitions

- [ ] Define `ircpipe` with core, engine, and web applications.
- [ ] Define `ircpipe_web` with core and web applications only.
- [ ] Define `ircpipe_engine` with core and engine applications only.
- [ ] Set `ircpipe` as the default release for simple builds.
- [ ] Use a traceable release version derived from the application version and source revision.
- [ ] Generate Unix release executables required by the supported deployment hosts.
- [ ] Add release-specific runtime configuration without a generic deployment-mode switch.
- [ ] Ensure combined release startup requires no node, cookie, or engine-node variables.
- [ ] Add web and combined server commands that set `PHX_SERVER=true`.
- [ ] Add migration commands only to combined and web/migrator artifacts.
- [ ] Keep migration execution out of engine startup and engine artifacts.
- [ ] Make release wrappers release-name aware rather than hard-coding `ircpipe`.
- [ ] Include digested frontend assets in combined and web releases only.
- [ ] Build all three releases from a clean checkout.

#### Release-specific background work

- [ ] Define the complete combined Oban queue and plugin configuration.
- [ ] Define web-owned notification and web-maintenance queues.
- [ ] Define engine-owned connection and session queues.
- [ ] Assign every cron entry to exactly one release.
- [ ] Ensure a worker that expects a local session is enabled only in engine-capable releases.
- [ ] Verify jobs inserted by one role can be executed by the owning role through shared PostgreSQL tables.
- [ ] Test that duplicate queue ownership does not occur in split mode.

#### Dependency distribution

- [x] Fetch `ircxd` from `HashNuke/ircxd` and pin the resolved commit in `mix.lock`.
- [ ] Publish `ircxd` to Hex with a version compatible with the core, engine, and web applications.
- [ ] Replace the Git dependency with a Hex version constraint after publication.
- [ ] Verify core, engine, and web declare `ircxd` wherever their code references it, with one resolved version across the umbrella.
- [ ] Verify the web release starts only short-lived directory discovery clients and no per-user session or hosted-server listeners.

#### Combined Docker image for Railway and similar platforms

- [x] Start from the Phoenix-generated multi-stage release Dockerfile.
- [x] Build the current combined release from the repository root.
- [x] Fetch the GitHub `ircxd` dependency without a sibling checkout.
- [ ] Adapt Docker copy/cache layers to the umbrella layout.
- [ ] Build the explicit combined `ircpipe` release.
- [ ] Keep build-only Erlang, Elixir, Node.js, npm, and compiler tools out of the final image.
- [ ] Run the final image as an unprivileged user.
- [ ] Add a container health endpoint and platform health-check configuration.
- [ ] Add Railway configuration with `/app/bin/migrate` as pre-deploy and `/app/bin/server` as start command.
- [ ] Document required environment variables and the one-replica constraint.
- [ ] Smoke-test the image with managed/external PostgreSQL and no cluster variables.

#### Self-hosted VPS Compose package

- [x] Provide a production Compose file with one combined app and one PostgreSQL service.
- [x] Persist PostgreSQL to an explicitly configured host path.
- [x] Wait for PostgreSQL health before starting the app.
- [x] Run combined migrations before the app starts.
- [ ] Adapt the Compose build to the umbrella Dockerfile.
- [ ] Bind the application safely for use behind an HTTPS reverse proxy.
- [ ] Document database backup and restore for the configured persistent path.
- [ ] Document upgrade, migration failure, and application rollback procedures.
- [ ] Validate a clean VPS installation using only the repository, Docker, Compose, and documented environment file.

#### Artifact exit gate

- [ ] All three OTP releases build in CI.
- [ ] The combined image has no split-mode configuration requirement.
- [ ] The web release may include `ircxd` for directory discovery but has no engine supervision, per-user IRC sessions, or hosted IRC listener.
- [ ] The engine release has no Endpoint or frontend assets.
- [ ] Only combined and web/migrator artifacts can run migrations.
- [ ] Combined Docker and Compose smoke tests pass.

### Workstream 4: Enable the distributed split runtime

Size: **XL**. Risk: **Critical**. This introduces partial failure and singleton-safety cases that do not exist in combined mode.

#### Distribution and network configuration

- [ ] Finalize `RELEASE_NODE`, `RELEASE_COOKIE`, and `IRCPIPE_ENGINE_NODE` names.
- [ ] Use stable long node names resolvable on the private network.
- [ ] Generate and store a high-entropy deployment-specific cookie.
- [ ] Configure fixed distribution port ranges for firewalling.
- [ ] Keep EPMD and distribution ports off public interfaces.
- [ ] Define the same explicit Phoenix PubSub pool size on both nodes; initial value is 1.
- [ ] Add static web-to-engine connection attempts during web startup.
- [ ] Add bounded reconnect/backoff behavior after node loss.
- [ ] Decide whether production hosts need TLS distribution based on their network trust boundary.
- [ ] Document cookie rotation as a coordinated web-and-engine restart.

#### Engine singleton and discovery

- [ ] Implement the lightweight globally registered engine marker.
- [ ] Return the owning engine node without routing all work through the marker process.
- [ ] Replace `Ircpipe.Irc.SingleNodeGuard` with an engine-only singleton guard.
- [ ] Permit any number of non-engine web nodes to join without stopping engine supervision.
- [ ] Refuse engine startup before opening sessions when another marker exists.
- [ ] Handle stale marker cleanup after an ordinary node shutdown.
- [ ] Log and expose marker acquisition and ownership status.
- [ ] Document that this guard is not network-partition-safe fencing.

#### Remote engine calls

- [ ] Add the split-mode `EngineClient` adapter.
- [ ] Resolve the engine node through the marker and static configuration.
- [ ] Invoke only the stable engine API entry point remotely.
- [ ] Apply per-operation timeouts and normalize timeout exits.
- [ ] Normalize node-down and engine-not-started failures to `:engine_unavailable`.
- [ ] Reject unsupported request versions and operations explicitly.
- [ ] Add protocol capability/version reporting for diagnostics.
- [ ] Correlate remote logs using request IDs.
- [ ] Ensure remote retries cannot duplicate non-idempotent sends.
- [ ] Verify the engine reloads ownership and authorization data from PostgreSQL for every mutation.

#### Cross-node PubSub

- [ ] Start identically named PubSub instances on web and engine.
- [ ] Verify engine broadcasts reach the web node through Distributed Erlang.
- [ ] Verify combined mode still uses the same publish calls locally.
- [ ] Verify web restart and resubscription do not require engine restart.
- [ ] Verify missed events are recovered through browser bootstrap/history rather than a new raw-event journal.
- [ ] Document the compatible rolling procedure required before any future PubSub pool-size change.

#### Degraded behavior and observability

- [ ] Keep login, account, settings, and persisted history available while the engine is down.
- [ ] Return a clear degraded error for IRC mutations while the engine is unavailable.
- [ ] Keep pending browser sends recoverable or retryable according to operation semantics.
- [ ] Expose web-to-engine connection state in health and telemetry.
- [ ] Expose engine marker ownership, active sessions, reconnects, and ingestion failures.
- [ ] Add alerts for engine loss, duplicate-engine attempts, and sustained RPC timeouts.
- [ ] Ensure web startup is not permanently blocked by temporary engine unavailability.

#### Split integration harness and tests

- [ ] Start distinct web and engine nodes against one test PostgreSQL database and local IRC server.
- [ ] Confirm status, connect, disconnect, join, part, send, command, direct-message, and channel-list operations cross the boundary.
- [ ] Confirm engine PubSub events reach a user channel on the web node.
- [ ] Stop web and prove the engine session PID remains alive.
- [ ] Deliver messages while web is down, restart web, and recover them through history/bootstrap.
- [ ] Stop engine and verify persisted web features remain available with degraded mutation errors.
- [ ] Restart engine and restore only desired-connected recent sessions and their autojoins.
- [ ] Start a second engine and prove it cannot acquire ownership or open duplicate IRC connections.
- [ ] Simulate a request timeout and prove errors are normalized without crashing callers.
- [ ] Verify web N operates with the supported engine N-1 protocol.
- [ ] Add an optional split Compose harness if it materially simplifies CI and local integration testing.

#### Distributed-runtime exit gate

- [ ] Restarting web leaves the engine marker, hosted server, and outbound session PIDs alive.
- [ ] Starting a second engine fails safely before session startup.
- [ ] Cross-node calls and events pass the integration suite.
- [ ] Engine loss produces a visible degraded state without taking down persisted web features.
- [ ] Combined mode remains green and requires no distribution settings.

### Workstream 5: Enable the hosted `Ircxd.Server`

Size: **XL**. Risk: **High**. This can proceed after the engine application boundary is stable and is not required for the first outbound-client split deployment.

#### Domain and adapter work

- [ ] Define hosted-server domain tables separately from per-user outbound server connections.
- [ ] Generate additive migrations for hosted server accounts, credentials, channels, membership, and policy state.
- [ ] Implement the Ecto-backed `Ircxd.Server` application adapter.
- [ ] Keep `ircxd` protocol structs behind the engine boundary.
- [ ] Define durable identities for users who authenticate to the hosted IRC server.
- [ ] Add revocable IRC-specific passwords or tokens for OAuth-only users.
- [ ] Encrypt hosted IRC credentials at rest.
- [ ] Add audit data for credential creation, revocation, and authentication failures.

#### Supervision and isolation

- [ ] Start the hosted server under `HostedIrcServerSupervisor` in the engine application.
- [ ] Keep the hosted server outside the outbound session system's `:one_for_all` boundary.
- [ ] Prove a hosted-server crash does not restart outbound sessions.
- [ ] Prove an outbound registry or supervisor failure does not terminate hosted clients.
- [ ] Define restart intensity and failure escalation for the hosted server.

#### Network and abuse controls

- [ ] Configure listener addresses and ports per deployment mode.
- [ ] Configure TLS certificates, protocol versions, and renewal/reload behavior.
- [ ] Expose hosted IRC ports only from engine-capable deployments.
- [ ] Add connection, registration, authentication, message-rate, and resource limits.
- [ ] Add operational logging and metrics without logging credentials or private message bodies unnecessarily.
- [ ] Document firewall, DNS, TLS, and reverse-DNS requirements.

#### Hosted-server exit gate

- [ ] Hosted IRC clients remain connected across web-only deployments.
- [ ] Hosted-server failures remain isolated from outbound sessions.
- [ ] Authentication, authorization, TLS, limits, and persistence have integration coverage.
- [ ] Combined and split deployment documentation covers the correct exposed ports.

### Workstream 6: Build first-party bare-host deployment automation

Size: **L**. Risk: **High**. The web/engine split has little operational value until ordinary web deployment is repeatable and cannot accidentally restart the engine.

#### Host and directory preparation

- [ ] Pin Erlang, Elixir, Node.js, and npm versions used on production build hosts.
- [ ] Provision a dedicated unprivileged runtime user and a controlled deployment user.
- [ ] Create source, build, release, current-symlink, and shared-data directories with documented ownership.
- [ ] Store runtime environment files outside the source checkout with restrictive permissions.
- [ ] Provision the shared PostgreSQL database and backup policy separately from application releases.
- [ ] Restrict EPMD and distribution ports to the private host/network path.

#### Repeatable build commands

- [ ] Fetch the repository without mutating the currently running release.
- [ ] Resolve and check out an exact requested commit.
- [ ] Refuse deployment from a dirty or unexpected source state.
- [ ] Acquire a deployment lock so two builds cannot race.
- [ ] Fetch only production Mix dependencies and verify `mix.lock`.
- [ ] Install frontend dependencies with `npm ci` for web-capable releases.
- [ ] Build digested frontend assets for combined and web releases.
- [ ] Assemble `ircpipe_web` into a new versioned directory.
- [ ] Assemble `ircpipe_engine` into a new versioned directory only during an explicit engine deployment.
- [ ] Record commit, release version, toolchain versions, and build timestamp with each artifact.
- [ ] Keep a bounded number of prior release directories for rollback.

#### systemd services and runtime configuration

- [ ] Add an `ircpipe-web.service` unit using the stable web symlink.
- [ ] Add an `ircpipe-engine.service` unit using the stable engine symlink.
- [ ] Configure graceful SIGTERM shutdown and realistic start/stop timeouts.
- [ ] Configure automatic restart policy without causing a rapid crash loop.
- [ ] Configure stable `RELEASE_NODE` values for both services.
- [ ] Configure the shared cookie and static engine node without exposing them in the repository.
- [ ] Configure fixed distribution ports.
- [ ] Ensure only the web service sets `PHX_SERVER=true`.
- [ ] Ensure only the engine service receives engine-only IRC listener and credential secrets.
- [ ] Send logs to journald and preserve request/session correlation metadata.

#### Web deployment flow

- [ ] Build and smoke-check the new web release before activation.
- [ ] Run migrations from the new web release exactly once.
- [ ] Abort before activation if migration fails.
- [ ] Atomically repoint the web `current` symlink.
- [ ] Restart only `ircpipe-web.service`.
- [ ] Wait for web health and web-to-engine connectivity.
- [ ] Automatically repoint and restart the prior web release if the new health check fails and rollback is schema-compatible.
- [ ] Prove the engine PID and active session PIDs do not change during web deployment.

#### Engine deployment flow

- [ ] Require an explicit engine-deploy command or flag.
- [ ] Confirm the target schema is compatible before engine shutdown.
- [ ] Build and smoke-check the new engine release before activation.
- [ ] Gracefully stop the old engine, accepting one IRC reconnect window.
- [ ] Atomically repoint the engine `current` symlink.
- [ ] Start the new engine and verify marker ownership.
- [ ] Verify desired-connected session restoration and autojoins.
- [ ] Roll back to the prior compatible engine release if startup or restoration checks fail.

#### Deployment exit gate

- [ ] A web-only deployment is one repeatable command and leaves engine processes running.
- [ ] An engine deployment is explicit and cannot occur as a side effect of web deployment.
- [ ] Migration failure leaves the previous web release selected and running.
- [ ] Health failure triggers or clearly instructs a compatible rollback.
- [ ] Secrets, source checkout, build output, and runtime processes have appropriate ownership and permissions.
- [ ] The runbook has been exercised on a production-like host.

### Workstream 7: Verification, compatibility, and operational hardening

Size: **L**. Risk: **High**. These checks turn a working demo into a supportable production architecture.

#### CI and artifact verification

- [ ] Run root formatting, compilation with warnings as errors, frontend type checks, frontend tests, Storybook build, and Elixir tests.
- [ ] Build all three releases from a clean CI checkout.
- [ ] Inspect release contents to enforce the expected application and asset boundaries.
- [ ] Build and smoke-test the default combined Docker image with no cluster variables.
- [ ] Validate and smoke-test the production Compose package.
- [ ] Run the split-node integration harness in CI.
- [ ] Verify migrations run once and never from engine startup.
- [ ] Verify only the intended Oban queues, plugins, and cron entries run in each release.

#### Compatibility and failure testing

- [ ] Verify every request/event version accepts documented fields and rejects unsupported versions.
- [ ] Verify contracts contain no Ecto structs, PIDs, functions, exceptions, or engine-private structs.
- [ ] Verify web N with engine N-1 for every supported operation and event.
- [ ] Verify additive migrations work while the older engine remains online.
- [ ] Verify a web rollback after additive migrations.
- [ ] Verify an engine rollback while the schema remains compatible.
- [ ] Inject web crashes, engine crashes, node disconnects, RPC timeouts, PostgreSQL outages, and IRC outages.
- [ ] Verify no failure path starts a second active engine.
- [ ] Verify browser history reconciliation after missed PubSub events.
- [ ] Verify retention, unread counts, mentions, notifications, presence, and direct messages across the split boundary.

#### Security and operational documentation

- [ ] Threat-model Erlang cookie compromise and distribution-port exposure.
- [ ] Verify private firewall rules from production-like hosts.
- [ ] Verify release users cannot read secrets belonging only to the other role unless required.
- [ ] Document PostgreSQL backup, restore, and recovery testing.
- [ ] Document expand-and-contract migrations and destructive-change coordination.
- [ ] Document web deployment, engine deployment, rollback, and combined-mode recovery.
- [ ] Document cookie rotation and node-name changes.
- [ ] Document health signals, dashboards, logs, and alerts.
- [ ] Update README with combined Docker and Compose first, and split deployment as an advanced operator workflow.
- [ ] Run `mix precommit` after all implementation and documentation changes.

#### Final exit gate

- [ ] Combined Docker/Compose remains the simple supported default.
- [ ] First-party web deploys do not reconnect IRC clients.
- [ ] Engine restarts restore desired-connected sessions and never restore paused sessions.
- [ ] Split failure modes are visible, bounded, and documented.
- [ ] Rollback procedures have been rehearsed against a production-like database copy.
- [ ] The initial production rollout is approved with an explicit maintenance window.

## Initial production rollout checklist

The first transition from combined to split mode requires one planned IRC reconnect. Do not overlap the combined engine and standalone engine.

- [ ] Confirm all workstream 0 through 4, 6, and 7 exit gates are complete.
- [ ] Confirm a fresh PostgreSQL backup and tested restore path.
- [ ] Confirm the selected combined, web, and engine artifacts come from the same compatible source version.
- [ ] Deploy the combined release containing the engine boundary and additive schema.
- [ ] Verify combined production behavior before cutover.
- [ ] Build the initial standalone engine and web releases on their destination host or hosts.
- [ ] Run required additive migrations from the new web release.
- [ ] Stop the combined application and confirm all old engine/session processes are gone.
- [ ] Start the standalone engine and confirm marker ownership.
- [ ] Verify desired-connected session restoration, autojoins, ingestion, and hosted-server listeners if enabled.
- [ ] Start the standalone web release and confirm engine connectivity.
- [ ] Verify login, bootstrap, history, status, send, receive, PubSub, notifications, and degraded-state reporting.
- [ ] Restart web once and prove engine and session PIDs survive.
- [ ] Record the cutover result, versions, and rollback point.

## Rollback checklists

### Split web release rollback

- [ ] Confirm the prior web release is compatible with the current additive schema.
- [ ] Repoint the web symlink to the prior release.
- [ ] Restart only the web service.
- [ ] Verify health, engine connectivity, bootstrap, history, and send/receive.
- [ ] Leave the engine running throughout the rollback.

### Split engine release rollback

- [ ] Confirm the prior engine release is compatible with the current schema and web protocol.
- [ ] Stop the current engine cleanly.
- [ ] Repoint the engine symlink to the prior release.
- [ ] Start the prior engine and verify marker ownership.
- [ ] Verify desired-connected restoration and autojoins.
- [ ] Verify web-to-engine operations and events.

### Emergency return to combined mode

- [ ] Confirm the selected combined release is compatible with the current schema.
- [ ] Stop the standalone engine first and confirm marker/session shutdown.
- [ ] Stop the standalone web release.
- [ ] Start the compatible combined release against the same database.
- [ ] Verify combined engine ownership and desired-connected restoration.
- [ ] Verify browser bootstrap, history, send, receive, and notifications.

Never start combined mode while the standalone engine is active. Additive schema changes should make application rollback possible without database rollback; destructive migrations require a separate coordinated plan.

## Deferred work

- Multiple engine replicas
- Per-connection leases and fencing tokens
- Automatic engine failover during a network partition
- Zero-disconnect engine upgrades
- Raw IRC event journaling beyond canonical message persistence
- A Redis, NATS, or RabbitMQ transport
- Multi-region web or engine operation
- Hot code upgrades and `relup`
