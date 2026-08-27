# Application split plan

## Status

Proposed architecture and implementation plan.

## Summary

Ircpipe will support two deployment modes from one codebase:

1. **Combined mode** runs the web application and IRC engine in one BEAM release. This remains the default for local development, Railway, Docker Compose, and simple personal deployments.
2. **Split mode** runs a small, long-lived IRC engine release separately from the frequently deployed web release. The two releases share PostgreSQL and communicate over Distributed Erlang.

Both modes must use the same engine client API and the same message-ingestion path. Combined mode is not a second implementation: the engine client resolves to a local engine in combined mode and a clustered engine in split mode.

The split is intended to avoid restarting IRC client connections and the hosted `Ircxd.Server` when only Phoenix, React, authentication, APIs, or other web-facing behavior changes. It does not require hot code upgrades or release upgrade instructions (`relup`).

## Goals

- Keep outbound IRC sessions alive across ordinary web deployments.
- Keep clients connected to the hosted `Ircxd.Server` across ordinary web deployments.
- Keep the engine release small, stable, and rarely deployed.
- Preserve the existing low-latency message path: persist once, then broadcast immediately after commit.
- Keep the default Docker and Railway deployment as simple as it is today.
- Keep one PostgreSQL database, one canonical Ecto schema history, and one migrations directory.
- Use one application-level interface for IRC operations in both combined and split modes.
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
| Engine client               |                                 | Discovery IRC clients       |
| Repo + Vault + PubSub       |                                 | Hosted Ircxd.Server         |
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

## OTP application and release layout

Convert the repository into an umbrella with these applications:

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
- Server-channel discovery connections
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
- The web side of `Ircpipe.EngineClient`

### Releases

Define three releases:

| Release | Applications | Intended use |
| --- | --- | --- |
| `ircpipe` | core + engine + web | Default Docker, Railway, development, simple self-hosting |
| `ircpipe_web` | core + web | Frequently deployed web tier in split mode |
| `ircpipe_engine` | core + engine | Small long-lived engine in split mode |

The `ircxd` dependency belongs to `ircpipe_engine`, so it is present in the combined and engine releases but absent from the web-only release.

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

The current `Ircpipe.Chat` namespace may be separated gradually. Moving a schema into `ircpipe_core` does not require moving every context that uses that schema into the core application.

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

`Ircpipe.EngineClient` resolves the marker, obtains its node, and invokes a stable engine API on that node. In combined mode the resolved node is the local node.

The existing `Ircpipe.Irc.SingleNodeGuard` must be replaced. The new guard permits web nodes in the cluster and fails engine startup when another engine marker is already registered.

This global registration is a singleton guard for the supported static two-node topology, not a substitute for database-backed fencing. Network-partition-safe engine failover remains deferred.

### Request contract

Cluster requests use a versioned envelope and plain terms:

```elixir
%{
  version: 1,
  operation: :send_message,
  request_id: "uuid",
  user_id: 123,
  connection_id: 456,
  payload: %{buffer_id: "channel:789", body: "hello"}
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

### Initial operations

The first version of the engine API must cover every current direct web-to-engine call:

- Batch connection status
- Ensure/start connection
- Disconnect connection
- Quiesce connection for deletion
- Request channel join
- Part channel
- Send channel message or action
- Send direct message
- Execute a validated IRC command intent
- Fetch the live server channel list

`Ircpipe.EngineClient` maps node-down, timeout, and engine-not-started failures into stable application errors such as `:engine_unavailable` and `:not_connected`.

### Internal event contract

Engine-to-web PubSub events also use versioned plain maps. They represent committed application facts such as:

- Message committed
- Buffer joined or left
- Connection status changed
- Presence synchronized or changed
- Direct-message thread changed
- Command result committed

Browser payload formatting remains in `ircpipe_web`. Internal events must contain enough IDs and committed values for the web node to format the event without consulting engine process state.

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

## Supervision

### Core supervision

Each node starts its own core infrastructure:

- Vault
- Repo
- Phoenix PubSub
- Shared telemetry needed by that release

### Engine supervision

The hosted IRC server must be isolated from outbound sessions:

```text
IrcpipeEngine.Supervisor (:one_for_one)
  EngineMarker
  ConnectionOperationLock
  OutboundSessionSystemSupervisor
  DiscoveryRefresher (when enabled)
  HostedIrcServerSupervisor
```

`Ircxd.Server` must not be placed inside the outbound session subsystem's current `:one_for_all` boundary. A hosted-server failure must not restart every outbound client session, and an outbound registry failure must not terminate all hosted IRC clients.

### Web supervision

The web release starts Phoenix Endpoint last, after Repo, PubSub, and the engine client monitor are available. Engine unavailability must put IRC mutations into a clear degraded state; it must not prevent the web application from serving login, settings, or persisted history.

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

Railway and similar platforms can continue replacing the single combined service normally. Such a replacement reconnects IRC sessions, which is an accepted tradeoff for the simple deployment mode.

### Split production experience

Provide a separate advanced deployment example, such as `docker-compose.split.yml`, with:

- One PostgreSQL service
- One `ircpipe_engine` service
- One `ircpipe_web` service
- A private network between web and engine
- Stable long node names
- A shared, deployment-specific Erlang cookie
- Static engine-node configuration for the web release
- Migrations run once by a one-shot task before the web release starts
- No automatic migration command on the engine
- Public HTTP port exposed only by the web service
- Hosted IRC ports exposed only by the engine service when enabled

The web node should attempt a static connection to the configured engine node. DNS-based automatic clustering and horizontal engine discovery are outside the first implementation.

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

## Implementation phases

### Phase 1: Introduce the engine boundary without changing deployment

- Add versioned internal request, reply, and event contracts.
- Add `Ircpipe.EngineClient` and a local engine API/marker.
- Refactor every web call to `Session`, `SessionSupervisor`, and `SessionLocator` through `EngineClient`.
- Refactor connection deletion and server-directory lookup through the same interface.
- Move the existing desired-state connect/disconnect operation behind the engine boundary while preserving its write-before-process-action ordering.
- Change engine-originated PubSub messages from browser-specific payloads to stable internal events; serialize them for the browser in `ircpipe_web`.
- Keep the existing single application and run all tests in combined mode.

Exit criteria:

- No module under `IrcpipeWeb` calls an IRC registry, session, locator, or supervisor directly.
- Combined mode behavior and browser protocol remain unchanged.
- Ordinary messages still commit before being pushed and do not pass through Oban.
- Paused connections remain paused across combined-app and engine restarts.

### Phase 2: Establish application ownership

- Create `ircpipe_core`, `ircpipe_engine`, and `ircpipe_web` OTP applications.
- Move schemas, Repo, Vault, migrations, PubSub, and cluster contracts into core.
- Move IRC processes, stable ingestion, discovery connections, and engine-owned workers into engine.
- Move Phoenix and browser-facing code into web.
- Resolve compile-time dependencies until both engine and web can compile without depending on each other.
- Keep module renames minimal where retaining the existing `Ircpipe` namespace avoids needless churn.

Exit criteria:

- The web application compiles without `ircxd` or engine implementation modules.
- The engine application compiles without Phoenix Endpoint, controllers, HTML, or frontend assets.
- The combined release starts core infrastructure only once.

### Phase 3: Produce the three releases

- Define `ircpipe`, `ircpipe_web`, and `ircpipe_engine` releases.
- Preserve existing release migration commands for the combined and web/migrator artifacts.
- Add release-specific Oban queue configuration.
- Update the Dockerfile to build the combined release by default and accept an explicit release target for advanced builds.
- Keep the existing Compose file on the combined release.

Exit criteria:

- Existing `docker compose` instructions remain valid.
- The combined image requires no cluster configuration.
- The web-only artifact does not contain `ircxd` or start IRC listeners.
- The engine artifact does not contain frontend assets or start an HTTP endpoint unless a narrowly scoped operational endpoint is explicitly added later.

### Phase 4: Enable clustered split mode

- Add static web-to-engine node connection on split-mode boot.
- Replace `SingleNodeGuard` with the engine singleton marker/guard.
- Verify Phoenix PubSub propagation between the two nodes.
- Implement stable node-down, timeout, and unsupported-version error handling.
- Add the advanced split Compose/deployment example.

Exit criteria:

- Restarting the web release leaves the engine PID and IRC session PIDs alive.
- After web restart, the browser reloads persisted messages and receives new realtime messages.
- Starting a second engine fails safely before opening duplicate IRC connections.

### Phase 5: Enable the hosted `Ircxd.Server`

- Add it under the isolated hosted-server supervisor branch.
- Implement the production Ecto-backed server adapter.
- Keep hosted-server domain tables distinct from per-user outbound server connections.
- Add IRC-specific account credentials or revocable app passwords for OAuth-only users.
- Configure listener address, TLS, limits, and exposed ports per deployment mode.

The hosted server can be enabled after the application split; it does not block extracting outbound sessions first.

### Phase 6: Documentation and operational hardening

- Update README with combined mode first and split mode second.
- Document engine upgrades as ordinary stop/start deployments that reconnect IRC sessions; do not introduce `relup`.
- Add engine and web health/telemetry signals.
- Document backup, migration, cookie rotation, and rollback procedures.
- Run `mix precommit` and fix all issues after implementation changes are complete.

## Test and verification plan

### Contract tests

- Every engine request and event version accepts documented fields and rejects unsupported versions.
- Requests and replies contain no Ecto structs, PIDs, functions, or engine-private structs.
- Newer web code handles the previous supported engine protocol version.
- Engine errors map to stable web-facing errors.

### Combined-mode tests

- Existing controller, Channel, IRC session, retention, presence, and notification tests continue to pass.
- `EngineClient` resolves the local engine.
- Message ingestion commits before PubSub broadcast.
- The browser-facing payloads remain compatible.
- Explicit disconnect persists `paused`, explicit reconnect persists `connected`, and passive bootstrap never starts a paused connection.

### Split-mode integration tests

- Start distinct web and engine nodes against one test PostgreSQL database and local IRC test server.
- Confirm status, connect, join, part, send, command execution, and channel listing cross the engine boundary.
- Confirm engine PubSub events reach a user channel on the web node.
- Stop the web node and assert the engine session process remains alive.
- Deliver messages while the web node is unavailable, restart web, and verify bootstrap/history contains them.
- Start a second engine and assert it cannot acquire engine ownership.
- Restart the engine and confirm it restores desired-connected recent sessions and their autojoins without restoring paused sessions.
- Disconnect the cluster and verify the web reports `engine_unavailable` without losing access to persisted history or account pages.

### Release and deployment tests

- Build all three releases in CI.
- Smoke-test the default combined Docker image with no cluster variables.
- Smoke-test the advanced split Compose topology.
- Verify migrations execute once and the engine does not attempt to migrate.
- Verify only intended Oban queues execute in each release.
- Verify an N web release can communicate with the supported N-1 engine release.

## Initial production rollout

The first transition from combined to split mode requires one planned IRC reconnect:

1. Deploy the combined release containing the completed engine boundary and compatible schema.
2. Verify combined mode in production.
3. Build the initial engine and web releases from that compatible version.
4. Stop the combined application to guarantee it releases all IRC sessions.
5. Start the standalone engine and allow it to restore recent sessions and autojoins.
6. Start the web release and verify cluster connectivity, PubSub, status, send, and history.
7. Thereafter, deploy the web release independently while leaving the engine running.

Do not overlap the old combined engine and new standalone engine during cutover.

## Rollback

To return from split mode to combined mode:

1. Stop the standalone engine first.
2. Stop the web release.
3. Start the compatible combined release against the same database.
4. Allow the combined engine to restore sessions.

Never start combined mode while the standalone engine is active. Additive schema changes should make rollback possible without database rollback; destructive migrations require their own coordinated plan.

## Deferred work

- Multiple engine replicas
- Per-connection leases and fencing tokens
- Automatic engine failover during a network partition
- Zero-disconnect engine upgrades
- Raw IRC event journaling beyond canonical message persistence
- A Redis, NATS, or RabbitMQ transport
- Multi-region web or engine operation
- Hot code upgrades and `relup`
