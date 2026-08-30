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

On a clean VPS with Git, Docker Engine, and the Compose plugin:

```bash
git clone git@github.com:HashNuke/topics.club.git /srv/topics_club/source
cd /srv/topics_club/source
cp env.example .env
```

Set every required value in `.env`, especially a strong `POSTGRES_PASSWORD`. Compose passes the password as a discrete PostgreSQL setting rather than embedding it in a URL, so reserved URL characters are supported.

PostgreSQL data is stored in the Compose-managed `postgres_data` volume. Validate the resolved configuration and start the stack:

```bash
docker compose --env-file .env -f docker-compose.prod.yml config --quiet
docker compose --env-file .env -f docker-compose.prod.yml up -d --build
docker compose --env-file .env -f docker-compose.prod.yml ps
curl --fail http://127.0.0.1:4000/health
```

The application waits for PostgreSQL health, runs migrations, and then starts the combined release. Keep exactly one `app` container.

## Advanced split deployment on one bare host

For the concise start-to-finish procedure, see `docs/deployment-separate-nodes.md`.

The first-party split deployment is for the TopicsClub-operated environment where web-only
deployments must leave IRC connections alone. It runs `topics_club_gateway` and
`topics_club_engine` as separate systemd services on one Ubuntu 26.04 x86-64 host. It does not
support a second engine host or horizontal replicas. The two BEAM nodes use short names and bind
EPMD plus distribution ports `4369`, `4370`, and `4371` to loopback.

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

Then create the two application environment files directly on the destination. Do not copy a
filled environment file from the repository or commit it, encrypted or otherwise. The committed
`tools/deploy/gateway.env.example` and `tools/deploy/engine.env.example` files are variable lists
only. On the server:

```bash
install -d -m 0755 /etc/topics-club
install -m 0600 /dev/null /etc/topics-club/gateway.env
install -m 0600 /dev/null /etc/topics-club/engine.env
editor /etc/topics-club/gateway.env
editor /etc/topics-club/engine.env
```

Both files need the same `IRC_CREDENTIALS_KEY` and `RELEASE_COOKIE`; neither contains
`DATABASE_URL`, because both services load it from the generated `db.env`. Use stable
`RELEASE_NODE` names `topics_club_gateway@localhost` and `topics_club_engine@localhost`. Gateway
also needs `SECRET_KEY_BASE`, `GATEWAY_HOST`, and `PORT`; it defaults the engine target to
`topics_club_engine@localhost`.
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
bin/apptools deploy --host root@203.0.113.10 --tag latest
bin/apptools deploy --host root@203.0.113.10 --tag 20260828.1
```

The combined command deploys gateway first, while the old engine remains online, then deploys the
matching engine. The gateway build runs locked migrations before its symlink changes. An explicit
engine deployment is accepted only after the same tag and commit are active in a healthy gateway,
which confirms that its schema migration step completed:

```bash
bin/apptools deploy gateway --host root@203.0.113.10 --tag latest
bin/apptools deploy engine --host root@203.0.113.10 --tag latest
```

A gateway-only deployment never selects or restarts the engine service. The deploy program checks
out an exact clean commit away from the running release, builds into a new versioned directory,
checks the artifact manifest, atomically changes the role's `current` symlink, restarts only that
role, and checks readiness. It keeps five release directories per role and two recent source
checkouts, protecting current and previous targets. A deployment lock rejects concurrent builds.
Re-running the active tag is a no-op.

Gateway readiness requires PostgreSQL plus connectivity to the engine. During the first empty-host
bootstrap only, gateway database readiness is sufficient until the engine starts. Engine readiness
requires three consecutive marker RPC checks; when gateway is running, its end-to-end health must
also become healthy. A failed migration leaves the previous gateway selected and running. A failed
post-activation health check automatically restores and restarts the previous compatible role.

Inspect the services and immutable build metadata with:

```bash
systemctl status topics-club-gateway topics-club-engine
journalctl -u topics-club-gateway -u topics-club-engine
cat /srv/topics-club/current-gateway/deploy-manifest
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
bin/apptools rollback engine --host root@203.0.113.10
```

Gateway rollback leaves the engine running; engine rollback leaves the gateway running. The
rollback swaps stable symlinks, restarts only the selected service, health-checks it, and restores
the original selection if that check fails. It never reverses database migrations. Deploy and roll
back only across additive, application-compatible migrations; a destructive migration needs its
own coordinated database recovery plan.

For local production-like rehearsal, the resettable pseudo-VPS has the same Ubuntu version,
systemd services, SSH-as-root entry point, target-side Docker builder, 1.5 GiB RAM limit, build swap,
and PostgreSQL sidecar:

```bash
bin/apptools testvps create
bin/apptools provision --repository file:///mnt/topics-club.git
bin/apptools deploy --tag latest
bin/apptools testvps acceptance
bin/apptools testvps status
bin/apptools testvps destroy
```

The `file:///mnt/topics-club.git` repository is a test-only read-only mount. Production provision
uses the public HTTPS remote. Reset and destroy affect only the exact named pseudo-VPS containers,
network, PostgreSQL data volume, Docker build-data volume, and ignored `.apptools/vps` test state.

`testvps acceptance` is an explicit, production-like split-release check and is not part of
`mix precommit` or routine CI. It briefly stops and restarts the pseudo-VPS gateway while leaving
the engine running. A temporary local IRC sidecar exchanges outbound and inbound messages without
publishing an IRC port or contacting a public network. The check verifies persistence and gateway
history recovery while also proving that the engine PID and original IRC socket survive. It then
removes the temporary database records and IRC container and restores the gateway if the check
fails partway through.

## Optional PostgreSQL backup and restore

Backup automation and restore rehearsal are deferred and are not part of the current deployment
work. The following manual procedure is retained as operator guidance for when backups are enabled.

Create logical backups outside the Docker volume; copying the live PostgreSQL data directory is not a safe backup procedure:

```bash
docker compose --env-file .env -f docker-compose.prod.yml exec -T postgres \
  pg_dump -U postgres -d topics_club_prod -Fc > topics_club-$(date +%Y%m%d-%H%M%S).dump
```

Test restores on another PostgreSQL instance regularly. Restoring over the production database is destructive: stop the application, preserve a second current backup, recreate or clean the target database, restore with `pg_restore`, and start the application only after `pg_restore` succeeds. For example, against an already empty `topics_club_prod` database:

```bash
docker compose --env-file .env -f docker-compose.prod.yml stop app
docker compose --env-file .env -f docker-compose.prod.yml exec -T postgres \
  pg_restore -U postgres -d topics_club_prod --exit-on-error < topics_club-backup.dump
docker compose --env-file .env -f docker-compose.prod.yml up -d app
```

## Upgrade and rollback

Fetch and check out an exact commit rather than deploying a moving working tree. Build the image and run migrations before replacing the running application:

```bash
git fetch --all --prune
git checkout <exact-commit>
docker compose --env-file .env -f docker-compose.prod.yml build app
docker compose --env-file .env -f docker-compose.prod.yml run --rm app /app/bin/migrate
docker compose --env-file .env -f docker-compose.prod.yml up -d --no-deps app
curl --fail http://127.0.0.1:4000/health
```

If migration fails, do not replace the running application. Investigate and either fix forward or restore the tested database backup; never mark a failed migration as applied manually.

For an application rollback, check out the prior exact commit, rebuild it, and replace only the `app` service. Roll back only when that release is compatible with every migration already applied. Additive migrations are normally compatible; destructive schema changes require a coordinated recovery plan. A database rollback uses the tested restore procedure above and causes downtime.
