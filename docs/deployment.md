# Combined deployment

The supported default deployment is the combined `topics_club` release: one application instance and one PostgreSQL database. Do not run more than one application replica. The engine owns long-lived IRC sessions in memory and does not yet have database-backed leases or fencing.

## Required application configuration

Every production deployment requires:

- PostgreSQL connection settings. Container platforms normally provide `DATABASE_URL`;
  alternatively set all of `DATABASE_HOST`, `DATABASE_USER`, `DATABASE_PASSWORD`, and
  `DATABASE_NAME`.
- `SECRET_KEY_BASE`: generate with `mix phx.gen.secret`.
- `IRC_CREDENTIALS_KEY`: generate with `mix topics_club.gen_credentials_key` and retain for the lifetime of the encrypted data.
- `GATEWAY_HOST`: public HTTPS hostname.
- `GOOGLE_CLIENT_ID` and `GOOGLE_CLIENT_SECRET`: Google OAuth credentials.
- `VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY`, and `VAPID_SUBJECT`: Web Push credentials generated with `mix topics_club.gen_vapid_keys`.

`PORT` defaults to `4000`; Railway supplies it automatically. `POOL_SIZE` defaults to `10`.
`DB_QUEUE_TARGET` and `DB_QUEUE_INTERVAL` both default to `5000` milliseconds, allowing short
inbound IRC bursts to wait for a database connection instead of immediately exhausting Ecto's
checkout queue. Discovery is disabled by default in production. The normal and advanced settings
for each deployment are documented in `docs/env-vars.md`.

The image runs as an unprivileged user. It exposes `/health`, which returns HTTP 200 only when Phoenix can query PostgreSQL. The image-level health check calls that endpoint. Combined mode needs no Erlang node name, cookie, engine-node hostname, or clustering variable.

## Railway and similar container platforms

Railway detects the repository `Dockerfile`. Configure exactly one service replica with:

- Pre-deploy command: `/app/bin/migrate`
- Start command: `/app/bin/server`
- Health-check path: `/health`
- Health-check timeout: `300` seconds

Attach a managed PostgreSQL service or provide an external `DATABASE_URL`, then add the other required application variables above. The Docker build consumes Railway's `RAILWAY_GIT_COMMIT_SHA` so the OTP release version identifies the deployed source revision. Railway's health probe reaches `/health` directly over its private HTTP path; production SSL redirection excludes only that readiness path while normal browser requests still redirect to HTTPS.

Railway's repository-level `railway.toml` and `railway.json` configuration is deprecated and stops being read on 2026-12-01. Its replacement, `.railway/railway.ts`, owns the complete linked Railway project; omitted services and databases are deletion candidates. Run `railway config pull` against the real project before adopting Infrastructure as Code, add the remaining required settings above to the imported application service, review `railway config plan`, and only then apply it. This repository intentionally does not provide a project-blind IaC file.

## VPS installation with Docker Compose

The production Compose package binds the application to `127.0.0.1:4000` and does not publish PostgreSQL. Put an HTTPS reverse proxy such as Caddy, nginx, or Traefik on the same host and proxy to that loopback address. Use a Compose override if a different host interface or port is required; bind only to a private interface and restrict it with the host firewall.

On a clean VPS with Git, OpenSSL, Docker Engine, and the Compose plugin:

```bash
git clone git@github.com:HashNuke/topics.club.git /srv/topics_club/source
cd /srv/topics_club/source
bin/setup-compose your-host.example.com
```

The setup helper generates `POSTGRES_PASSWORD`, `SECRET_KEY_BASE`, and
`IRC_CREDENTIALS_KEY`, writes the file with mode `0600`, and never changes an
existing `.env`. Add Google OAuth credentials and, when wanted, Web Push values
before starting the public service. Compose passes the database password as a
discrete PostgreSQL setting rather than embedding it in a URL, so reserved URL
characters are supported.

PostgreSQL data is stored in the Compose-managed `postgres_data` volume. Validate the resolved configuration and start the stack:

```bash
docker compose config --quiet
docker compose up -d --build
docker compose ps
curl --fail http://127.0.0.1:4000/health
```

The application waits for PostgreSQL health, runs migrations, and then starts the combined release. Keep exactly one `app` container.

## Advanced split deployment on one bare host

For the concise start-to-finish procedure, see `docs/deployment-separate-nodes.md`.

The first-party split deployment is for the TopicsClub-operated environment where web-only
deployments must leave IRC connections alone. It runs `topics_club_gateway`,
`topics_club_wirekeeper`, and `topics_club_engine` as separate systemd services on one Ubuntu 26.04
x86-64 host. Wirekeeper owns IRC sockets so engine-only restarts can resume them. The topology does
not support a second engine host or horizontal replicas. The three BEAM nodes use short names and
bind EPMD plus distribution ports `4369`, `4370`, `4371`, and `4372` to loopback.

The destination must be reachable as `root@IP` with an existing SSH key. A separate command
installs PostgreSQL 18 from the official PostgreSQL Ubuntu repository, starts it on loopback, creates
the application database and role, and generates `/etc/topics-club/db.env` on the destination. The
application deploy never creates, replaces, backs up, or restores the database.
The local operator machine needs `uv`, while the destination needs no preinstalled
Erlang, Elixir, Node.js, or npm. Provisioning installs Docker and builds every release on the
destination in a pinned Ubuntu 26.04 builder, so NIFs match the target userspace. A host below the
recommended build memory gets a persistent 4 GiB `/swapfile` when it has less than 4 GiB of swap;
the supported runtime RAM floor remains 1.5 GiB.

First provision the database. The command generates a database password on the destination and
writes the resulting `DATABASE_URL` to a root-owned, mode `0600` file. It never prints or transfers
the password, and a repeat run does not rotate it:

```bash
bin/apptools provision-db --host root@203.0.113.10
```

Install the three application environment files from the local 1Password CLI session:

```bash
bin/apptools deploy install-secrets --env prod --host root@203.0.113.10
```

The command resolves `app-secrets/topics-club-prod` in memory and streams the role-specific files
over encrypted SSH. It creates no local plaintext file and prints no secret values. It generates
an Ed25519 deploy key on the destination only when one does not already exist, and prints the
public key for you to add to the GitHub repository as a read-only deploy key. Both environment
Gateway and engine receive the shared `IRC_CREDENTIALS_KEY`; all three files receive the shared
`RELEASE_COOKIE`. None contains `DATABASE_URL`: gateway and engine load it from `db.env`, while
Wirekeeper does not access the database. The command selects Wirekeeper in `engine.env`, assigns
stable role-specific `RELEASE_NODE` names, and installs all files with mode `0600`.
Only the gateway starts Phoenix. Add engine-only hosted-IRC listener secrets to `engine.env` when
that feature exists. Application provisioning checks the role files' existence, ownership, and
mode without reading, printing, templating, replacing, or transferring their contents. It also
verifies `db.env` metadata without reading its contents.

Provision the one destination repeatedly with the same command. Subsequent convergences are
no-ops unless declared host configuration changed:

```bash
bin/apptools provision --host root@203.0.113.10
```

The repository defaults to `https://github.com/HashNuke/topics.club.git`. Create a release tag with
`bin/release`, push it to `origin`, and deploy either the newest numeric release tag or an exact tag:

```bash
bin/apptools deploy wirekeeper --host root@203.0.113.10 --tag latest
bin/apptools deploy --host root@203.0.113.10 --tag latest
bin/apptools deploy --host root@203.0.113.10 --tag 20260828.1
```

The first command is required once on an empty host. Wirekeeper then has its own deliberately slow
release lifecycle. The default `deploy` command updates gateway first and engine second without
selecting or restarting Wirekeeper, so routine application releases preserve its process, sockets,
buffers, and checkpoints. The gateway build runs locked migrations before its symlink changes.
Each role can also be selected explicitly:

```bash
bin/apptools deploy gateway --host root@203.0.113.10 --tag latest
bin/apptools deploy wirekeeper --host root@203.0.113.10 --tag latest
bin/apptools deploy engine --host root@203.0.113.10 --tag latest
```

A default, gateway-only, or engine-only deployment never selects or restarts Wirekeeper. Update
Wirekeeper only with an explicit `deploy wirekeeper` after reviewing the socket interruption. The
deploy program checks out an exact clean commit away from the running release, builds into a versioned directory,
checks the artifact manifest, atomically changes the role's `current` symlink, restarts only that
role, and checks readiness. It keeps five release directories per role and two recent source
checkouts, protecting current and previous targets. A deployment lock rejects concurrent builds.
Re-running the active tag is a no-op.

Gateway readiness requires PostgreSQL plus a successful call through the versioned engine RPC
contract. During the first empty-host bootstrap only, gateway database readiness is sufficient
until the engine starts. Wirekeeper readiness requires three consecutive local RPC checks and
transport API version 1. Engine readiness requires three consecutive RPC checks of its marker,
engine protocol version, and its configured IRC transport: direct mode succeeds locally, while
Wirekeeper mode makes a bounded call from the engine node to the configured Wirekeeper node and
requires transport API version 1. This detects wrong node names, cookie mismatches, distribution
failures, and incompatible Wirekeeper releases. A failed migration leaves the previous gateway selected
and running. A failed post-activation health check automatically restores and restarts the previous
compatible role.

Inspect the services and immutable build metadata with:

```bash
systemctl status topics-club-gateway topics-club-wirekeeper topics-club-engine
journalctl -u topics-club-gateway -u topics-club-wirekeeper -u topics-club-engine
cat /srv/topics-club/current-gateway/deploy-manifest
cat /srv/topics-club/current-wirekeeper/deploy-manifest
cat /srv/topics-club/current-engine/deploy-manifest
curl --fail http://127.0.0.1:4000/health
```

## Health, logs, and external alerts

The application writes logs to standard output. Railway and Docker collect that stream directly;
the split systemd services send it to journald. No log collector, dashboard, or alert-delivery
provider is built into TopicsClub.

In split mode `/health` keeps returning HTTP 200 while PostgreSQL and the gateway are available,
even when the engine is disconnected. Its top-level `status` is then `degraded`, and the nested
`engine.status` explains whether the engine is `disconnected` or `unavailable`. This prevents an
engine outage from making a platform restart the healthy gateway. An external monitor should parse
the response and require the top-level status to be `ok`; the deployment program uses the same
rule. Combined mode reports the engine as `local`.

Operational failures have stable, searchable event names:

| Event | Meaning |
|---|---|
| `event=engine_node_disconnected` | The split gateway lost its engine node. |
| `event=engine_marker_duplicate` | A second visible engine attempted to start and was rejected. |
| `event=engine_rpc_timeout` | One gateway-to-engine request exceeded its operation timeout. |
| `event=irc_ingestion_failed` | An inbound IRC event could not be persisted. |

Connection and marker acquisition use the corresponding informational
`event=engine_node_connected` and `event=engine_marker_acquired` entries. Event logs contain IDs,
operation names, nodes, timeout values, and failure classes; they do not contain IRC credentials or
message bodies.

For the first production deployment, point one operator-selected external monitor at `/health` and
alert after repeated `degraded` responses. If a log service is added later, alert immediately on a
duplicate marker and use a short rolling count for RPC timeouts and ingestion failures so one
transient failure does not page anyone. Alert destinations and thresholds belong to that deployment,
not to the open-source application.

Roll back one application role to its recorded previous release with:

```bash
bin/apptools rollback gateway --host root@203.0.113.10
bin/apptools rollback wirekeeper --host root@203.0.113.10
bin/apptools rollback engine --host root@203.0.113.10
```

Gateway and engine rollback leave Wirekeeper running. A Wirekeeper rollback necessarily replaces
its in-memory IRC sockets. The rollback swaps stable symlinks, restarts only the selected service,
health-checks its live contracts, and restores the original selection if that check fails.
Gateway/engine compatibility is checked through the versioned engine RPC contract;
engine/Wirekeeper compatibility is checked through the Wirekeeper transport API version. Rollback
never reverses database migrations. Deploy and roll back only across additive,
application-compatible migrations; a destructive migration needs its own coordinated database
recovery plan.

For local production-like rehearsal, the resettable pseudo-VPS has the same Ubuntu version,
systemd services, SSH-as-root entry point, target-side Docker builder, a 2 GiB aggregate app-host
RAM limit, build swap, and a PostgreSQL sidecar:

```bash
bin/apptools testvps create
bin/apptools provision --repository file:///mnt/topics-club.git
bin/apptools deploy wirekeeper --tag latest
bin/apptools deploy --tag latest
bin/apptools testvps acceptance
bin/apptools testvps status
bin/apptools testvps destroy
```

The 2 GiB app-host cgroup includes the base Ubuntu/systemd processes, target-side Docker daemon and
cache, and the gateway, Wirekeeper, and engine BEAM nodes together. The separately limited 384 MiB
PostgreSQL sidecar is outside that cgroup, as is the temporary synthetic IRC sidecar used by
acceptance and load tests. Consequently, this measures a 2 GiB application host with an external
database; it is not evidence for fitting PostgreSQL and TopicsClub into one 2 GiB machine.
The Wirekeeper systemd service sets `LimitNOFILE=65536`; without that explicit soft limit, the
operating-system default can cap the transport near 1,000 sockets before memory becomes the
constraint under test.

New pseudo-VPS containers start with an additional 4 GiB swap allowance so destination-side release
builds work. Capacity measurements must not use that allowance. These commands switch the exact
named container between the two repeatable modes:

```bash
bin/apptools testvps runtime-limits # 2 GiB aggregate RAM; swap disabled
bin/apptools testvps build-limits   # 2 GiB RAM plus 4 GiB build swap
```

`bin/apptools testvps load` switches to runtime limits before sampling and restores build limits
after successful lifecycle cleanup. See `docs/load-tests.md` for the ramp and result format.

The `file:///mnt/topics-club.git` repository is a test-only read-only mount. Production provision
uses the public HTTPS remote. Reset and destroy affect only the exact named pseudo-VPS containers,
network, PostgreSQL data volume, Docker build-data volume, and ignored `.apptools/vps` test state.

`testvps acceptance` is an explicit, production-like split-release check and is not part of
`mix precommit` or routine CI. It first stops and restarts the pseudo-VPS engine while leaving
Wirekeeper running. A temporary local IRC sidecar exchanges outbound and inbound messages without
publishing an IRC port or contacting a public network. The check injects traffic while the engine is
down, verifies Wirekeeper buffering and replay persistence, and proves that the Wirekeeper PID and
original IRC socket survive. It then restarts Wirekeeper while leaving the engine PID unchanged and
proves that node-loss monitoring makes the live engine establish a fresh IRC connection and persist
new traffic. Finally it removes the temporary database records and IRC container and restores either
service if the check fails partway through.

## Optional PostgreSQL backup and restore

Backup automation and restore rehearsal are deferred and are not part of the current deployment
work. The following manual procedure is retained as operator guidance for when backups are enabled.

Create logical backups outside the Docker volume; copying the live PostgreSQL data directory is not a safe backup procedure:

```bash
docker compose exec -T postgres \
  pg_dump -U postgres -d topics_club_prod -Fc > topics_club-$(date +%Y%m%d-%H%M%S).dump
```

Test restores on another PostgreSQL instance regularly. Restoring over the production database is destructive: stop the application, preserve a second current backup, recreate or clean the target database, restore with `pg_restore`, and start the application only after `pg_restore` succeeds. For example, against an already empty `topics_club_prod` database:

```bash
docker compose stop app
docker compose exec -T postgres \
  pg_restore -U postgres -d topics_club_prod --exit-on-error < topics_club-backup.dump
docker compose up -d app
```

## Upgrade and rollback

Fetch and check out an exact commit rather than deploying a moving working tree. Build the image and run migrations before replacing the running application:

```bash
git fetch --all --prune
git checkout <exact-commit>
docker compose build app
docker compose run --rm app /app/bin/migrate
docker compose up -d --no-deps app
curl --fail http://127.0.0.1:4000/health
```

If migration fails, do not replace the running application. Investigate and either fix forward or restore the tested database backup; never mark a failed migration as applied manually.

For an application rollback, check out the prior exact commit, rebuild it, and replace only the `app` service. Roll back only when that release is compatible with every migration already applied. Additive migrations are normally compatible; destructive schema changes require a coordinated recovery plan. A database rollback uses the tested restore procedure above and causes downtime.
