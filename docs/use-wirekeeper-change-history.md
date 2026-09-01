# Wirekeeper branch change history

This document supplies the rationale that was missing from five early subject-only commits on the
`use-wirekeeper` branch. Those commits have been pushed and are ancestors of deployed, immutable
release tags `20260901.1` through `20260901.3`. Rewording or splitting them now would change their
object IDs, invalidate the tags and deployment manifests, and require a destructive force-push.
The original IDs are therefore preserved and documented here.

Later commits on the branch use a smaller scope and carry detailed commit bodies. The repository's
current `mix precommit` gate also validates the integrated descendant rather than pretending that a
later test run reproduces each historical commit in isolation.

## `187e8c496c28e068800d8c80d4a21ac472a4cc8f` — replay-safe Wirekeeper effects

**Reason.** A pending managed command could be durable in Postgres while its IRC socket write was
uncertain across an engine crash. Blind replay risked a duplicate `JOIN`; assuming the write had
happened risked losing it. The fix needed one idempotency identity to cross the database, engine,
Ircxd transport, and Wirekeeper generation boundary.

**Atomic behavior change.** The commit adds durable JOIN-attempt identities and command lifecycle
state, passes those identities through the Ircxd transport, and adds generation-local
`send_data_once` suppression in Wirekeeper. It also makes ingestion and command replay preserve the
same identity after engine restart, updates the client state exposed through the gateway, and
documents the protocol. These pieces were landed together because deploying only one layer would
either reject the new call contract or restore the original duplicate/lost-write window.

**Compatibility boundary.** Idempotent transport writes are optional in Ircxd. Direct/default
socket adapters continue to use the existing write path; Wirekeeper advertises and implements the
additional capability. Keys are scoped to one retained socket generation so an intentional fresh
generation is allowed to send again.

**Evidence added by the commit.** It adds or extends Wirekeeper `send_once`, transport, durable
command, managed JOIN, replay, and frontend reconciliation tests. Follow-up commit `8744f2c` pins
the expanded public Ircxd contract, and run `20260901t074527z` later proves exact outbound and
inbound effects after a real split engine restart.

## `f14016ea576ee06c0ed5da443c63536a315d441e` — durable JOIN rejection

**Reason.** IRC numerics such as `477` are part of the JOIN lifecycle, not merely display lines. If
the engine cleared its in-memory pending command before persisting the rejected membership and
failed command, a database outage or engine restart could turn a real rejection into a stuck or
misreported JOIN.

**Behavior change.** Rejection persistence now succeeds before pending JOIN/command state is
cleared. Persistence failures are fed into the Wirekeeper ingestion retry path, which keeps the
effect pending and suppresses misleading disconnect/reconnect notices while the same retained
record is retried. Successful rejection records the server-facing explanation used by the UI.

**Evidence added by the commit.** Focused tests cover failed rejection persistence, correlation of
managed and native JOIN failures, command-message terminal state, membership state, and engine
resume. The later full gate runs these as part of the engine suite.

## `e3850668170cc6229a9aafef4311ef19b5738905` — one default Compose path

**Reason.** The repository had a development-oriented `docker-compose.yml` and a separate
production file, while the quick start required users to copy and hand-edit secrets. That made the
default command surprising and allowed documentation and Compose behavior to drift.

**Behavior change.** The production-safe combined release becomes the default
`docker-compose.yml`; the old local PostgreSQL-only behavior moves to `docker-compose.dev.yml`.
`bin/setup-compose` creates a mode-`0600` `.env` with generated required secrets, validates its
hostname input, and refuses to alter an existing file. The removed `docker-compose.prod.yml`
invocations are replaced consistently in README, deployment, development, environment, and split
architecture documentation.

**Compatibility boundary.** This changes repository operator commands, not the TopicsClub runtime
or Ircxd API. Existing `.env` files are never overwritten, PostgreSQL remains unexposed in the
default production stack, and the application remains bound to loopback for a same-host HTTPS
proxy.

## `4c2da3b81fba8dbe49b12fb96ed5034dcb878199` — deterministic lifecycle rehearsal

**Reason.** Three independent rehearsal races prevented trustworthy measurements: canceling an
opening Wirekeeper caller could wait on graceful child termination, Python Fire represents a
comma-separated CLI value as a tuple, and Linux 6.8 exposes `memory.peak` as read-only.

**Behavior change.** Canceled opening generations are killed within their supervisor boundary;
load counts accept Fire's tuple/list representation; and a read-only cgroup peak is reset by
restarting only the disposable pseudo-VPS container, preserving release and database volumes, then
waiting for gateway health. The chosen reset method is recorded in the artifact.

**Evidence added by the commit.** Unit tests cover tuple parsing and both writable/read-only cgroup
paths. The gateway channel test is synchronized with its lifecycle outcome. Release tag
`20260901.2` identifies this exact revision and remains the intentionally long-lived Wirekeeper
release used by the final 4,000-session run.

## `791b683c9e82c50ee36dfdec5053f92158eac2b4` — truthful Wirekeeper metrics

**Reason.** The minimal Wirekeeper release deliberately has no Jason dependency. Evaluating a JSON
encoding expression inside that release could fail or tempt the production service to grow solely
for observability.

**Behavior change.** The load sampler asks Wirekeeper for diagnostics and Erlang runtime counters
over loopback distribution, then encodes the result on the always-running gateway node. Engine
restart sampling therefore remains independent of the engine, while Wirekeeper's production
dependency boundary stays unchanged.

**Evidence added by the commit.** A unit test pins the gateway role, Wirekeeper node, `:erpc` calls,
and JSON encoding location. The final split run records Wirekeeper connection, buffer, drop, memory,
process, port, and run-queue metrics at every checkpoint.

## Subsequent review fixes

The final review split new work into focused, reasoned commits:

- `6e78586` serializes concurrent transport-revision changes;
- `12b973f` reconciles a stale running session after a settings RPC failure;
- `a25d472` durably releases acknowledged ingestion claims after an engine crash;
- `8744f2c` pins the documented optional Ircxd idempotent-write contract;
- `9506d53` proves bidirectional traffic at the load ceiling;
- `40a35c3` replaces a scheduler-dependent failed-open test assertion; and
- `82dcf63` keeps read-only load sampling alive through an expected node transition; and
- `5da3cc8` keeps the applied transport revision immutable when session state refreshes its database
  row.

See `docs/wirekeeper.md` for the resulting architecture and `docs/load-tests.md` for the current
split-release capacity evidence and limitations.
