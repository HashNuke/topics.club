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
- [x] The repository is an umbrella containing core, engine, and web OTP applications.
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

The authoritative ownership and transition manifest is `config/boundaries.exs`. It tracks compiled production files, all 29 migration modules, and test-support files under the four deployable logical components plus `tooling` for root Mix tasks. The temporary `assembly` source owner disappeared with the empty root OTP application during the umbrella conversion; combined assembly is now release metadata rather than production code. Tooling is not an OTP application and is excluded from deployable-component cycle analysis. Migration files receive an owner, but Mix does not compile them into the application xref graph; their internal references therefore require migration tests and review rather than xref enforcement.

Run `mix ircpipe.check_boundaries` to validate the manifest against Mix's direct xref graph. The checker fails on unowned or multiply owned files, unknown components, cycles in the permanent allowed-dependency policy, actual deployable cycles outside the explicit transition-cycle baseline, new forbidden file edges, dependency-label escalation, malformed or duplicate exceptions, stale exceptions or transition cycles, and compiled production files missing from xref. `mix precommit` runs this check immediately after warning-free compilation.

The initial graph already has one temporary strongly connected component containing core, engine, and web because the monolith has allowlisted reverse edges in all three components. The checker records that component set explicitly and rejects a different or additional deployable strongly connected component. This baseline must disappear when the reverse edges are removed; it is not a permitted final umbrella topology.

The initial inventory records 36 exact temporary dependency edges:

| Source direction | Count | Required resolution |
| --- | ---: | --- |
| Core to web | 1 | Replace browser-shaped payload construction with a stable internal event boundary |
| Engine to web | 6 | Separate browser events and Web Push enqueueing from engine-owned persistence/effects |
| Web to engine | 29 | Route live operations through `EngineClient` and separate connection/deletion orchestration |

Every exception records its current xref label, responsible logical owner, reason, and removal checkpoint. The initial allowlist is capped at 36 entries, and a removed edge makes its exception stale and fails the check until the manifest is deliberately tightened. Mix xref reports dependencies at file-edge granularity: a second call added between an already-exempt source/target pair is not a new xref edge. Review and focused behavioral tests must therefore police call-site growth within an existing exception, while the automated gate prevents new file pairs and a growing exception count.

### Current monolith inventory

This inventory was refreshed at the workstream 1 exit audit on 2026-08-28. `config/boundaries.exs` is the file-level source of truth; the tables below record runtime behavior that xref cannot express. There are currently no temporary dependency exceptions and no deployable-component cycles.

#### Outbound IRC operations and local-process assumptions

No `IrcpipeWeb` module calls a long-lived session, session registry, locator, supervisor, or engine implementation module. Every per-user operation uses `Ircpipe.EngineClient`; the engine API reloads ownership from PostgreSQL and then calls the local process implementation. The web-owned directory worker is the one deliberate exception to using the per-user engine: it creates its own short-lived `Ircxd.Client` solely to issue `LIST`, owns that client for the duration of the request, and never uses the per-user registries.

| Public entry points | EngineClient operation | Engine implementation |
| --- | --- | --- |
| Bootstrap, connection index, Channel status sync | `connection_statuses` | `SessionLocator.status/1` through the engine API |
| Message/command validation needing live IRC support | `connection_info` | `Session.connection_info/1` |
| Bootstrap restore, connect/reconnect, join preparation | `ensure_connection` | Persist connected intent, then `SessionSupervisor.start_session/1` |
| REST/Channel disconnect | `disconnect_connection` | Persist paused intent, then `SessionSupervisor.stop_session/2` |
| REST connection deletion | `delete_connection` | Engine-owned quiescence, durable deletion jobs, and recovery |
| Topic, discovery, REST, and `/join` joins | `join_channel` | Persist connected intent, ensure session, then `Session.request_join/3` |
| REST, Channel, and `/part` leaves | `part_channel` | `Session.part/3` after membership ownership reload |
| Channel messages and actions | `send_channel_message` | `Session.say/3` or `Session.action/3` after membership reload |
| Direct messages and `/msg` | `send_direct_message` | `Session.privmsg_thread/4` after thread reload |
| Slash/quote commands | `execute_command` | Re-resolve command intent in the engine, then `Session.execute/5` |
| Live server channel directory and `/list` | `list_channels` | `Session.list_channels/1` |

The remaining modules that assume an IRC process is local are all engine-owned: `Ircpipe.Engine.API` and its local adapter, `Ircpipe.Chat.ConnectionDeletion` and its workers, `Ircpipe.Irc.Bouncer`, `SessionSupervisor`, `SessionLocator`, and the modules under `Ircpipe.Irc.Session`. The engine bouncer restores recent desired-connected sessions at engine startup; session registration restores persisted autojoins. No core module or web-owned worker has a local-session assumption.

#### Inbound facts, commit ordering, and browser delivery

| IRC-derived fact | Persistence path | Post-commit path |
| --- | --- | --- |
| Channel/server message or command transcript | Session event pipeline -> recorder -> `MessageIngestion`, `SystemMessages`, or `CommandMessages` transaction | `message_committed` -> web realtime handler -> `buffer:message`, `buffer:error`, or `buffer:system` |
| Direct message and thread state | Session event pipeline -> `DirectMessageIngestion` transaction | thread event plus `message_committed` -> `direct_message:thread` and `buffer:message` |
| Connection status/nickname | Session connection events -> `ConnectionLifecycle` transaction | `connection_status_changed` -> `server:status` |
| Join/part and buffer lifecycle | Join reconciliation -> membership persistence transaction | `buffer_joined` or `buffer_left` -> matching browser buffer event |
| Presence snapshot/diff | Session presence handlers -> `Presence` transaction | `presence_synchronized` or `presence_changed` -> matching browser presence event |
| Mention/direct-message notification | Message transaction inserts notification and one engine event job atomically | `notification_committed` -> web handler -> web-owned PushWorker |

Publish helpers reject calls from inside an outer rollback-capable transaction. Ordinary realtime message publication is synchronous after commit and does not use Oban; only notification delivery and durable deletion/event recovery use jobs. If web delivery is missed, bootstrap and cursor-based history reconciliation rebuild browser state from PostgreSQL.

`IrcpipeWeb.UserChannel` consumes one shared PubSub topic, `user:<user_id>`. Its internal tuple names and public pushes are:

| PubSub tuple | Browser event |
| --- | --- |
| `:buffer_message`, `:buffer_error`, `:buffer_system` | `buffer:message`, `buffer:error`, `buffer:system` |
| `:direct_message_thread`, `:direct_message_closed` | `direct_message:thread`, `direct_message:closed` |
| `:server_status` | `server:status` |
| `:presence_sync`, `:presence_diff` | `presence:sync`, `presence:diff` |
| `:buffer_joined`, `:buffer_left`, `:buffer_read` | `buffer:joined`, `buffer:left`, `buffer:read` |
| `:notification_preference` | `notification:preference` |

Authentication revocation uses the separate Phoenix socket topic `user_socket:session:<session-token-fingerprint>` with the `disconnect` event. It is web-only and is not part of the engine event contract.

#### Data and behavior ownership

The ownership manifest deliberately assigns files rather than relying on the mixed `Ircpipe.Chat` namespace:

| Owner | Schemas and behavior modules |
| --- | --- |
| Core | `User`, `ServerConnection`, `ChannelMembership`, `ChannelUser`, `Message`, `Notification`, `DirectMessageThread`, direct-message identity/store primitives, membership lookup, retention, presence queries, locking, Repo, Vault, and migrations |
| Shared protocol | `EngineClient` and its request/reply contracts, `InternalEvent` and its data contract, pure IRC command/identifier policy, and mention detection |
| Engine | Connection lifecycle/deletion, deletion request/event-batch schemas, join/part, ingestion, command/system messages, IRC-derived presence and direct-message behavior, engine API/local adapter, all per-user session processes, and engine-owned workers |
| Web | Accounts/session behavior, connection endpoint/snapshots and browser queries, read state, topics, notifications/Web Push, discovery, realtime serializers, RPC adapter, and all `IrcpipeWeb` modules |
| Tooling | Root Mix tasks, release metadata, and the non-deployable root integration-test project |

The less obvious web-owned schemas are `UserToken`, `Topic`, discovery `Network`/`ServerChannel`, `PushSubscription`, and `PushSubscriptionRateLimit`. The authoritative exact path list remains `config/boundaries.exs`, which fails on an unowned or multiply owned production, migration, or test-support file.

#### External dependency ownership

These are the current direct Mix dependencies. A component listed here must declare the dependency when its files move; depending on another child application must not be used to hide a direct library use.

| Dependency | Logical user |
| --- | --- |
| `bcrypt_elixir` | Core user schema |
| `cloak_ecto`, `postgrex` | Core persistence and encryption |
| `ecto_sql` | Core, engine, and web modules that directly use Ecto; Repo remains core-owned |
| `phoenix`, `phoenix_ecto`, `phoenix_html`, `phoenix_live_view`, `phoenix_live_dashboard`, `bandit` | Web; core will declare `phoenix_pubsub` directly after extraction instead of inheriting it through Phoenix |
| `ueberauth`, `ueberauth_google`, `swoosh`, `gen_smtp`, `gettext` | Web auth, mail, and presentation |
| `req`, `floki` | Web notification/discovery HTTP and discovery parsing |
| `telemetry_metrics`, `telemetry_poller` | Web telemetry; the shared EngineClient contract will declare `telemetry` directly after extraction |
| `jason` | Core Vault serialization and web JSON/push payloads |
| `oban` | Engine and web, with separate named instances and queues |
| `ircxd` | Shared protocol, engine sessions, web directory listing, and local-development tooling |
| `phoenix_live_reload`, `esbuild`, `tailwind`, `heroicons` | Web development/build tooling |
| `lazy_html` | Web tests only |

Direct production `ircxd` use is intentionally narrow:

- Shared: `Ircpipe.Chat.MentionDetection`, `Ircpipe.Irc.CommandRegistry`, and `Ircpipe.Irc.Identifier`.
- Engine: `Ircpipe.Engine.Serialization`, `Ircpipe.Irc.CommandResult`, `EventFormatting`, `SessionLocator`, and the `Ircpipe.Irc.Session` protocol modules.
- Web: `Ircpipe.Discovery.ServerChannelLister`, whose short-lived workers are why `ircpipe_web` still requires `ircxd` after the application split.
- Tooling: `Mix.Tasks.Ircpipe.SetupLocalIrc`.
- Core data/persistence has no direct `ircxd` use.

#### Configuration, environment, and secrets

| Configuration | Phase | Owner |
| --- | --- | --- |
| `:scopes`, Ueberauth providers, endpoint compile options, `:dev_routes`, production force-SSL/static manifest | Compile | Web |
| esbuild/tailwind versions and generators | Compile | Web build tooling |
| `:ecto_repos`, Repo and Vault configuration | Runtime | Core; both split releases start their own Repo/Vault instance |
| `:engine_client_adapter` | Runtime | Shared port selection; combined assembly selects local, web split release selects RPC |
| `:internal_event_adapter` | Runtime | Engine event-port selection; combined assembly selects the web adapter |
| `:irc_bouncer_enabled`, `Ircpipe.EngineOban` | Runtime | Engine |
| `:discovery_refresh_enabled`, `IrcpipeWeb.Oban`, Endpoint, Mailer, `:email_from`, WebPush | Runtime | Web |
| logger, Phoenix JSON library | Compile/runtime support | Assembly, with the consuming component retaining its direct library dependency |

Test-only application keys are not release configuration. They are narrow synchronization or failure seams owned by the module that reads them: `connection_*_barrier`, `connection_*_failure`, `engine_api_after_connection_load_barrier`, `engine_local_api_module`, `engine_client_test_pid`, `engine_client_test_reply`, `pause_direct_message_*`, `pause_notification_preference_broadcast`, `pause_push_*`, `pause_session_*`, `push_sender`, `push_test_pid`, `push_test_result`, `read_state_before_server_lock_barrier`, and `session_*_barrier`.

| Environment variable or secret | Release that genuinely needs it |
| --- | --- |
| `DATABASE_URL`, `ECTO_IPV6`, `POOL_SIZE` | Combined, web, and engine |
| `IRC_CREDENTIALS_KEY` | Combined and engine; web must stop loading encrypted IRC credentials before the key is removed from the web release |
| `SECRET_KEY_BASE`, `PHX_HOST`, `PORT`, `PHX_SERVER` | Combined and web |
| `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET` | Combined and web |
| `SMTP_*`, `EMAIL_FROM_*` | Combined and web |
| `VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY`, `VAPID_SUBJECT` | Combined and web |
| `ENABLE_DISCOVERY` | Combined and web |
| `RELEASE_NODE`, `RELEASE_COOKIE`; later `IRCPIPE_ENGINE_NODE` on web | Split runtime/distribution as described in the configuration contract |
| `POSTGRES_PASSWORD`, `IRCPIPE_POSTGRES_DATA`, `IRCPIPE_PORT` | Compose interpolation only, not application configuration |

#### Supervision and registered names

| Owner | Tree, strategy, and stable names |
| --- | --- |
| Combined release | The release boot script starts the core, engine, and web OTP applications directly; there is no empty assembly supervisor or fourth production application |
| Core | `Ircpipe.CoreSupervisor`, `:one_for_one`; `Ircpipe.Vault`, `Ircpipe.Repo`, and `Ircpipe.PubSub` |
| Engine | `Ircpipe.EngineSupervisor`, `:one_for_one`; global engine marker, `Ircpipe.Engine.OperationLock`, `Ircpipe.Engine.RequestTaskSupervisor`, `Ircpipe.EngineOban`, and `Ircpipe.Irc.SessionSystemSupervisor` |
| Engine session subsystem | `:one_for_all`; `SingleNodeGuard`, `ConnectionOperationLock`, `ClientRegistry`, `SessionRegistry`, dynamic `SessionSupervisor`, and `Bouncer`. Per-connection session/client names use `{user_id, connection_id}` registry keys |
| Web | `IrcpipeWeb.Supervisor`, `:one_for_one`; Telemetry, `EngineRestoreTaskSupervisor`, `EngineRestorer`, `IrcpipeWeb.Oban`, optional `Discovery.Refresher`, and Endpoint last |

Shared Repo, Vault, and PubSub start once in combined mode. In split mode each node starts its own core runtime instance against the shared database; only the engine starts the session subsystem and only the web starts Endpoint.

#### Future paths and test destinations

Extraction preserves module names and relative paths. No module rename is bundled with a filesystem move.

| Current ownership/path | Future source destination | Future focused-test destination |
| --- | --- | --- |
| Core and shared entries in `config/boundaries.exs` | `apps/ircpipe_core/lib/...` | `apps/ircpipe_core/test/...` |
| Engine entries, including selected `lib/ircpipe/chat` files | `apps/ircpipe_engine/lib/...` | `apps/ircpipe_engine/test/...` |
| Web entries in both `lib/ircpipe` and `lib/ircpipe_web` plus assets | `apps/ircpipe_web/lib/...`, `apps/ircpipe_web/assets/...` | `apps/ircpipe_web/test/...` |
| Root `mix.exs` release metadata | Umbrella combined-release assembly; no production module | Root integration tests |
| `lib/mix/**` | Umbrella root tooling | Root tooling tests |
| Cross-component release, boundary, and distributed integration tests | No child source owner | Umbrella root integration test directory |

The pre-umbrella discovery baseline partitions every current ExUnit file exactly once:

| Logical test owner | Files | Tests | Future physical expectation |
| --- | ---: | ---: | --- |
| Core data/persistence | 9 | 27 | `ircpipe_core` |
| Shared protocol/contracts | 7 | 35 | `ircpipe_core` |
| Engine | 57 | 269 | `ircpipe_engine` |
| Web | 50 | 319 | `ircpipe_web` |
| Combined assembly | 1 | 6 | Umbrella root |
| Tooling | 2 | 14 | Umbrella root |
| Cross-component integration | 2 | 22 | Umbrella root |
| **Total** | **128** | **692** | **692 discovered from the umbrella root** |

The future child expectations are therefore core 62, engine 269, and web 319, with 42 root assembly/tooling/integration tests. The two explicitly cross-component files are `connections_concurrency_test.exs` and `direct_messages_test.exs`; keeping them at the root avoids inventing a false child owner. This is a discovery baseline, not a requirement that a child test suite boot unrelated child applications after extraction.

The mechanical extraction ultimately classified tests by whether their setup can run against one child application without a false dependency. The umbrella command now discovers 37 core tests, 67 engine tests, 172 web tests, and 421 root integration/tooling tests: 697 tests in total, including the five boundary regressions added during extraction. The root tests run through `test/mix.exs`, a test-only Mix project outside `apps/`; it starts all three real applications but is not included in any release.

#### Browser and deployment compatibility baseline

Every current JSON route in the router has a controller test under `test/ircpipe_web/controllers/api`; the bootstrap test freezes its complete top-level payload and the focused controller tests freeze each route's success/error shapes. `UserChannelTest` covers every inbound Channel command and every public pushed event. `RealtimeHandlerTest` now freezes the exact before/after translation for every engine realtime fact, every message destination, and all three message event types. React tests cover bootstrap parsing, reconnect cursors, missed history, command repair, and malformed recovery data.

The current deployment artifacts remain intentionally separate from the future first-party split deployment:

| Artifact | Current behavior |
| --- | --- |
| `Dockerfile` | Phoenix generated-style multi-stage build of the combined OTP release; suitable for Railway and other container platforms |
| `docker-compose.prod.yml` | Combined app plus PostgreSQL sidecar for a personal VPS; app runs migrations once before server startup |
| `docker-compose.yml` | Development PostgreSQL only |
| `rel/overlays/bin/migrate*` and `Ircpipe.Release` | Explicit release migration entry point |
| First-party topics.club deployment | Pull exact commit on destination, build bare releases there, migrate once, atomically select versioned release, and run systemd units; automation remains workstream 6 |

The engine protocol compatibility window is web N with engine N-1. Version 1 request/reply and event envelopes remain accepted for at least one engine release after a compatible web release ships. An incompatible field or semantic change requires a new protocol version, additive dual-version handling, an N-1 integration test, and deployment of the accepting side before the producing side.

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

“Safe” means the operation is designed to tolerate a retry after an unavailable/timeout result; callers still use bounded attempts and the same request ID. Message, command, part, and deletion operations are unsafe because an ambiguous timeout can follow successful IRC transmission, persistence, or deletion without enough retained result state to reproduce the original success reply. The client does not retry automatically in this phase—it exposes the classification in telemetry for the later RPC policy.

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

Engine ingestion atomically inserts an engine-owned `NotificationEventsWorker` job with the canonical notification row. That worker publishes the stable internal notification event after commit and snoozes without consuming attempts while the event adapter is unavailable. The web event handler then inserts the web-owned `PushWorker` job into the web queue. Engine code never inserts a web worker directly.

No queue may be enabled on a node where its worker assumes a local IRC registry unless the worker has first been refactored through `Ircpipe.EngineClient`.

The combined monolith now runs two named Oban instances so queue execution already follows the future release boundary:

| Instance owner | Queue/plugin | Workers or purpose |
| --- | --- | --- |
| Engine | `connection_deletions` queue | `ConnectionDeletionWorker`, `ConnectionDeletionEventsWorker`, and `ConnectionDeletionReconcilerWorker` |
| Engine | `internal_events` queue | `NotificationEventsWorker` durably publishes committed notification facts to the configured internal event adapter |
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

- [x] List every `IrcpipeWeb` call to `Session`, `SessionLocator`, `SessionSupervisor`, registries, and IRC process names.
- [x] List every non-web context or worker that assumes an IRC process is local.
- [x] Trace connect, disconnect, join, part, send, command, channel-list, and deletion flows from public entry point to session process.
- [x] Trace inbound message, presence, membership, command-result, and connection-status flows from IRC event through commit and PubSub.
- [x] Inventory every PubSub topic and payload currently consumed by `IrcpipeWeb.UserChannel`.
- [x] Inventory every Oban queue, plugin, cron entry, and worker, and assign each one to core, web, or engine.
- [x] Inventory all schemas and context modules and record their intended owning application.
- [x] Inventory compile-time and runtime configuration and classify it as shared, web-only, engine-only, or combined-only.
- [x] Inventory production secrets and identify which release genuinely requires each secret.
- [x] Inventory supervision children, restart strategies, registries, and globally or locally registered names.
- [x] Record the current browser REST and Channel payloads that must remain compatible.
- [x] Record the current release, migration, Docker, Compose, and service startup behavior.

#### Baseline verification

- [x] Run the current `mix precommit` suite successfully before structural changes.
- [x] Build the current combined Docker image from the repository root.
- [x] Validate the current production Compose configuration.
- [x] Add or preserve fixtures that exercise every engine operation before routing changes begin.
- [x] Add regression coverage for commit-before-broadcast behavior where it is not already explicit.
- [x] Add regression coverage for paused connections surviving bootstrap and process restarts.
- [x] Decide and document the supported engine protocol compatibility window; initial target is web N with engine N-1.

#### Exit gate

- [x] Every direct web-to-IRC dependency has an owner and a planned replacement operation.
- [x] Every background job has exactly one intended execution role.
- [x] Every current public browser payload has a regression test or deterministic fixture.
- [x] The combined baseline is green before workstream 1 begins.

### Workstream 1: Demarcate logical applications and introduce the engine boundary inside the monolith

Size: **XL**. Risk: **High**. This is the largest behavior-preserving refactor. It must land and pass its boundary gate before the umbrella exists; no task in workstream 2 is allowed to compensate for an unresolved dependency edge.

#### Declare module and runtime ownership

- [x] Create a checked-in ownership manifest covering every production module and assigning it to core, shared protocol/contracts, engine, web, assembly, or tooling.
- [x] Assign every test-support module and fixture to the component whose public behavior it supports.
- [x] Classify every external dependency by the logical component that uses it.
- [x] Classify every application environment key by logical owner and compile-time versus runtime use.
- [x] Classify every registered process name, Registry, supervisor, and PubSub name by logical owner.
- [x] Mark the intended future source and test destination for each current directory.
- [x] Preserve existing module names when moving them later unless a rename is independently justified and tested.
- [x] Record every temporary cross-boundary edge in a narrow allowlist with an owner and removal checklist item.
- [x] Document the allowed dependency graph in contributor guidance.

#### Extract shared protocol primitives from engine internals

- [x] Identify the current pure IRC identifier, command metadata, and validation code needed by more than one component.
- [x] Assign those current pure modules to the shared boundary even when their existing module name begins with `Ircpipe.Irc`.
- [x] Keep PIDs, process names, Registry lookups, supervisors, sockets, and `ircxd` runtime structs out of shared contracts.
- [x] Treat `ircxd` as an allowed shared library dependency while keeping all Ircpipe process ownership explicit.
- [x] Document which core, engine, and web modules directly use `ircxd` so each child application declares its actual dependency.
- [x] Add focused tests proving shared protocol modules run without engine supervision.

#### Enforce dependency direction in the monolith

- [x] Add an automated boundary check based on Mix's direct xref graph.
- [x] Reject new `IrcpipeWeb` references to engine implementation modules outside the exact migration allowlist.
- [x] Reject new core references to engine or web implementation modules outside the exact migration allowlist.
- [x] Reject new engine references to web modules outside the exact migration allowlist.
- [x] Reject cycles in the permanent dependency policy and actual deployable cycles outside the explicit transition-cycle baseline.
- [x] Keep the migration allowlist explicit, file-exact, label-sensitive, capped at the initial 36 edges, and free of namespace-wide exceptions.
- [x] Add the boundary gate to CI and enforce that exception, budget, and transition-cycle baseline changes only shrink once the base branch contains the manifest; the one-time initial-adoption PR runs the complete head policy because no base manifest exists to compare.
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

Checkpoint 5 is implemented and passed its GPT-5.6 Sol xhigh checkpoint review. Connection deletion now enters the engine through a versioned `delete_connection` operation, and the engine-owned `Ircpipe.Chat.ConnectionDeletion` module owns quiescence, durable recovery, final deletion, and deletion-event dispatch. The web connection facade no longer constructs deletion jobs, mutates durable connection intent, or calls engine locks and session supervision. Durable deletion workers acquire the engine operation lock before resuming. Web connection snapshots are now query-only; casemapping reconciliation stays in engine registration and join paths.

The stable event slice now emits versioned plain-map facts after commit for messages, notifications, connection status, buffer lifecycle, presence, and direct-message-thread lifecycle. Each version-one event type validates its exact top-level payload and canonical nested record shapes before dispatch. A small configured publisher port hands those facts to web-owned realtime and notification handlers in combined mode; engine and core modules no longer construct browser events or enqueue web jobs directly. Notification event jobs are inserted atomically with their notification rows and retry adapter failures through the engine-owned `internal_events` Oban queue. A failed deletion-event dispatch retains its committed batch and scheduled recovery job instead of acknowledging and deleting the batch.

The boundary graph now contains 237 owned files, no temporary dependency exceptions, and no deployable-component cycles. Dependency totals vary because Mix compiles environment-specific modules: the default environment currently reports 748 checked project edges and the test environment reports 763. An expanded set of 254 chat, notification, session, Channel, and event-contract tests passes. The existing React reconnect/bootstrap reconciliation suite passes all 98 tests, including cursor catch-up after socket loss, IRC server reconnect, malformed reconnect state, and missed command-status repair. After the first review fixes, full `mix precommit` passes with 686 Elixir tests, 227 frontend tests, type checking, the Storybook build, and the zero-exception boundary gate. The final reviewer reran 66 focused tests, both environment-specific boundary checks, and found no remaining correctness, SRP, or framework-building concern.

Checkpoint 6 completes the monolith exit audit and passed its GPT-5.6 Sol xhigh checkpoint review with no blocking findings. The checked-in inventory now classifies runtime flows, data and behavior ownership, direct dependencies, configuration and secrets, registered processes, browser contracts, deployment artifacts, future paths, and test destinations. Pull-request CI always runs the head boundary gate and, once the base contains the manifest, rejects any exception, exception-budget, or temporary-cycle addition relative to that base; the initial-adoption path has no older policy to compare. Focused regressions prove lifecycle retry after a committed intent/process-effect failure, join reactivation, paused bootstrap immutability, engine-start restoration with autojoins, ordinary-message commit-before-broadcast without Oban, exact internal-event-to-browser translation, and the final Channel forwarding paths. The complete ownership-partitioned suite passes 692 ExUnit tests, and `mix precommit` passes those tests plus 227 frontend tests, type checking, Storybook, and the 237-file/763-edge/zero-exception test boundary graph. A production build using the Dockerfile's compile-before-assets order assembles the combined release, and starting all `:ircpipe` applications through the release succeeds against PostgreSQL without split-mode variables.

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
- [x] Move desired-state mutation and the corresponding process action behind one engine client operation.
- [x] Ensure join/topic operations deliberately set desired state to connected before requiring a session.
- [x] Define retry behavior when intent persists successfully but the process action fails.
- [x] Restore recent desired-connected sessions and persisted autojoins after engine startup.
- [x] Prove that passive browser bootstrap never changes paused intent.

#### Stable internal event contract

- [x] Define a versioned internal event envelope with event ID, type, occurred-at value, and committed IDs/data.
- [x] Define message-committed events.
- [x] Define connection-status events.
- [x] Define buffer joined and left events.
- [x] Define presence synchronized and changed events.
- [x] Define direct-message-thread events.
- [x] Keep synchronous command results in versioned `EngineClient` replies and publish committed command transcript updates through `message_committed`, avoiding a duplicate event path.
- [x] Publish only after the transaction containing the canonical data commits.
- [x] Keep notification and deletion effects durable and retryable when the configured event adapter is unavailable.
- [x] Keep browser-specific field names and formatting out of engine events.
- [x] Convert internal events to the existing REST/Channel protocol in the web layer.
- [x] Add exact frozen before/after fixtures for every browser payload crossing the internal event boundary; existing controller and Channel tests cover the remaining web-owned payloads.
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
- [x] The ownership manifest maps cleanly to future `apps/ircpipe_core`, `apps/ircpipe_engine`, and `apps/ircpipe_web` destinations.
- [x] Existing controller, Channel, IRC, retention, presence, and notification tests remain green.
- [x] Ordinary messages still commit before broadcast and do not pass through Oban.
- [x] The browser protocol remains compatible.
- [x] `mix precommit` and a combined release smoke test pass.
- [x] Record the complete test count and per-component counts so the umbrella move cannot silently lose test discovery.

### Workstream 2: Mechanically extract the logical components into three OTP applications

Size: **M**. Risk: **Medium** after the workstream 1 exit gate passes. This workstream changes physical ownership and Mix configuration, not architecture or product behavior. If a move reveals a new dependency design problem, stop and resolve it in the monolith boundary model instead of adding a shortcut between child applications.

Checkpoint 7, the core ownership slice, started from `app-split` at `f232f00`. The pre-move baseline passes 692 ExUnit tests, 229 frontend tests, type checking, Storybook, and the 237-file/763-edge/zero-exception test boundary graph. Core-focused tests that currently construct fixtures through web- or engine-owned contexts must be given core-owned setup during the move or explicitly reclassified as root integration tests; child-application dependency cycles will not be introduced merely to preserve their current setup path.

The first physical core move is committed at `789036e`. `ircpipe_core` now owns its OTP application callback, Repo, Vault, PubSub supervisor, canonical migrations, shared schemas and persistence primitives, `EngineClient`, internal-event contracts, and shared IRC policy. The development seed script remains root tooling because it populates the web-owned `Topic` schema. The child application's 37 already-independent focused tests pass. The remaining 25 tests in the recorded future-core baseline still use combined web/engine setup and remain in the root suite until that setup is removed or the tests are explicitly classified as integration coverage. Root `mix test` runs 37 child tests plus 658 root tests with no failures; the increase from 692 to 695 is three focused regressions rather than duplicate discovery. Two exercise nested-child boundary enforcement: one proves graph prefixing and merging, and the other compiles an isolated child fixture with a forbidden call to a root web module and proves warnings-as-errors rejects the crossing. The third asserts that only `ircpipe_core` owns the Ecto repository configuration. The boundary gate now tracks and merges root and nested-child xref graphs, independently compiles every child in an isolated build path, and covers 238 owned files with zero temporary dependencies. Root `mix precommit` passes with the same 695 ExUnit tests, 229 frontend tests, type checking, Storybook, and the boundary gate. A production compile, asset build, and combined `ircpipe` release assembly also pass with `ircpipe_core` included as an OTP dependency. A clean, no-cache Docker build and image-content smoke check prove that the child Mix project, source, migrations, and release application are present in the image. Playwright's setup commands and Phoenix's development repository-status plug now explicitly resolve `Ircpipe.Repo` through `ircpipe_core`.

GPT-5.6 Sol xhigh approved the immutable core checkpoint at `703c785` with no remaining blocking, SRP, or over-engineering findings. It was merged into `app-split` at `eb04c34`. The engine ownership checkpoint proceeds from that merge on `app-split-umbrella-engine`; it will move only the files already assigned to engine ownership, preserve their module names and behavior, and retain combined-mode startup through the existing root composition application until the complete umbrella root is ready.

The engine production move is committed at `737f446`, with the isolated disabled hosted-server supervisor branch added at `fc979f9`. `ircpipe_engine` now owns the outbound IRC session tree, registries, protocol handlers, bouncer, connection restoration and autojoin behavior, canonical IRC ingestion and state updates, and engine-owned Oban workers. It declares only its direct core, Ecto, Oban, and Git-pinned `ircxd` dependencies and compiles 74 production files without Phoenix, Endpoint, or frontend dependencies. Its 67 independently runnable focused tests moved with it; 202 database-heavy tests from the recorded engine baseline remain root integration coverage because their setup crosses the future web boundary. Root `mix test` now runs 37 core tests, 67 engine tests, and 593 root tests, for 697 passing ExUnit tests in total. The boundary gate now merges compiler-manifest references with the per-project xref graphs so an available path dependency cannot hide a forbidden cross-application call; a real two-project fixture proves that a root web call into its engine path dependency is rejected. Root `mix precommit` passes with the same 697 ExUnit tests, 229 frontend tests, type checking, Storybook, and a 240-file/764-edge/zero-exception boundary graph. Production compilation, asset deployment, combined release assembly, a clean no-cache Docker build, image-content inspection, production Compose resolution, and a fresh-database release boot smoke all pass. The boot smoke proves the combined release runs the extracted engine application and both the outbound session and disabled hosted-server supervisor branches. GPT-5.6 Sol xhigh approved the immutable engine checkpoint at `37e89ad` with no remaining blocking, SRP, or over-engineering findings; it was merged into `app-split` at `0e6c728`.

The web ownership slice is committed at `400056c`. It moves all Phoenix, authentication, browser serialization, notifications, directory discovery, frontend, static, gettext, and web-owned worker code into `ircpipe_web` without changing production module names. The web child declares core and its direct libraries, including the Git-pinned `ircxd` needed by short-lived directory listing. Its 31 independently runnable files pass 172 tests without any engine implementation dependency; tests whose setup genuinely crosses application boundaries remain root integration coverage rather than forcing a test-only child dependency.

The repository root is now a true umbrella with only `ircpipe_core`, `ircpipe_engine`, and `ircpipe_web` under `apps/`. Root aliases explicitly orchestrate the three child suites and the non-deployable integration harness. The obsolete empty `Ircpipe.Application` and `Ircpipe.Supervisor` are removed. `mix precommit` passes 37 core, 67 engine, 172 web, and 421 root tests (697 total), 229 frontend tests, type checking, Storybook, warning-free compilation, and the 242-file/763-edge/zero-exception boundary graph. A clean combined release contains and starts exactly the three child applications, and its boot smoke starts all three role supervisors with no root supervisor. A no-cache Docker build exposed and fixed the last stale monolith reference in the colocated-hook import; the rebuilt image runs as `nobody`, contains no build toolchain or fourth Ircpipe application, and boots the same three supervisors. Production Compose resolution passes. GPT-5.6 Sol xhigh approved the implementation at `14c1ab6` with no blocking correctness, SRP, complexity, supervision, test-discovery, release-membership, CI, or container findings. Its two non-blocking documentation findings are addressed before merge, with final confirmation of that documentation-only commit pending.

#### Extraction rules

- [x] Do not begin the umbrella conversion until every workstream 1 exit-gate item passes.
- [x] Keep production module names unchanged during physical moves.
- [x] Move source modules and their focused tests as one coherent component slice.
- [x] Keep cross-component integration tests at the umbrella root or assign them an explicit owning application.
- [x] Make one ownership move at a time and run its focused tests before the next move.
- [x] Run the root boundary check after every component move.
- [x] Run root `mix precommit` after every completed ownership slice.
- [x] Compare discovered test counts with the recorded monolith baseline after every test-path change.
- [x] Do not introduce temporary child-application dependency cycles to make an intermediate move compile.
- [x] Do not combine module renaming or behavior changes with filesystem extraction.

#### Umbrella scaffolding

- [x] Create an umbrella root project with shared aliases and build paths.
- [x] Create `apps/ircpipe_core`.
- [x] Create `apps/ircpipe_engine`.
- [x] Create `apps/ircpipe_web`.
- [x] Preserve the existing `Ircpipe` and `IrcpipeWeb` module namespaces where renaming adds no value.
- [x] Move frontend assets and Storybook under the web application while preserving existing npm commands.
- [x] Update formatter inputs for the umbrella and all child applications.
- [x] Update test support paths and shared fixtures without introducing cross-application test coupling.
- [x] Update `mix setup`, asset, test, and `mix precommit` aliases at the umbrella root.
- [x] Prove root `mix test` discovers all previously recorded tests before moving the next component.

#### Core ownership

- [x] Move `Ircpipe.Repo` into core.
- [x] Move `Ircpipe.Vault` and encrypted Ecto types into core.
- [x] Move all shared Ecto schemas into core.
- [x] Move the canonical migrations directory into core and update repository migration paths.
- [x] Move PubSub naming and shared PubSub configuration into core.
- [x] Move versioned engine request, reply, and event definitions into core.
- [x] Move shared account identity needed to authorize engine requests into core.
- [x] Move database primitives needed by both roles into core without moving web or IRC policy indiscriminately.
- [x] Keep core free of dependencies on engine and web applications.

#### Engine ownership

- [x] Move outbound session supervision, registries, session modules, and protocol handlers into engine.
- [x] Move `Ircpipe.Irc.Bouncer` into engine.
- [x] Declare `ircxd` in engine for long-lived outbound sessions and hosted-server integration.
- [x] Move connection restoration and autojoin logic into engine.
- [x] Move canonical IRC message ingestion and IRC-derived state updates into engine.
- [x] Move engine-owned Oban workers into engine.
- [x] Add the isolated hosted-server supervisor branch even if the hosted server remains disabled initially.
- [x] Keep engine free of Phoenix Endpoint, controllers, HTML, authentication UI, React, and browser serialization.

#### Web ownership

- [x] Move Endpoint, router, controllers, Channels, socket, authentication, HTML, and mailer into web.
- [x] Move React, CSS, service worker, and Storybook assets into web.
- [x] Keep browser payload serializers in web.
- [x] Keep bootstrap, history, read-state, settings, and notification-preference behavior in web.
- [x] Keep Web Push delivery and other web-owned Oban workers in web.
- [x] Move directory discovery refresh and `ServerChannelLister` into web and declare its direct `ircxd` dependency.
- [x] Configure the web side of `EngineClient` without a compile-time dependency on engine implementation modules.

#### Dependency and supervision enforcement

- [x] Give each child application only the Hex/Git dependencies it uses.
- [x] Translate the already-green logical dependency graph into child `deps/0` declarations without adding new edges.
- [x] Make web compile without engine implementation modules while retaining `ircxd` for directory discovery.
- [x] Make engine compile without Phoenix Endpoint and frontend dependencies.
- [x] Check compile-connected dependency graphs for accidental cycles.
- [x] Start Vault, Repo, and PubSub exactly once per node.
- [ ] Start engine supervision only in combined and engine releases.
- [ ] Start Endpoint only in combined and web releases.
- [ ] Start release-owned Oban queues only after Repo is available.
- [x] Start Endpoint last in the web supervision tree.
- [x] Preserve configuration-change handling for Endpoint in the web application.

#### Umbrella exit gate

- [x] No production module was renamed solely because its file moved into a child application.
- [x] No product behavior or public payload changed as part of the extraction.
- [x] Each child application compiles and tests independently where practical.
- [x] The web application contains no engine implementation modules or long-lived user-session ownership.
- [x] The engine application contains no Endpoint, router, controller, HEEx, or React assets.
- [x] The combined supervision tree starts shared infrastructure once.
- [x] The combined application behaves the same as before the umbrella conversion.
- [x] Root and per-component test counts match the recorded pre-umbrella expectations.
- [x] The boundary checker passes without new exceptions or child-application dependency cycles.
- [x] Root `mix precommit` passes.

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
