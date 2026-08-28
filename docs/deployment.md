# Combined deployment

The supported default deployment is the combined `ircpipe` release: one application instance and one PostgreSQL database. Do not run more than one application replica. The engine owns long-lived IRC sessions in memory and does not yet have database-backed leases or fencing.

## Required application configuration

Every production deployment requires:

- PostgreSQL connection settings. Container platforms normally provide `DATABASE_URL`;
  alternatively set all of `DATABASE_HOST`, `DATABASE_USER`, `DATABASE_PASSWORD`, and
  `DATABASE_NAME`.
- `SECRET_KEY_BASE`: generate with `mix phx.gen.secret`.
- `IRC_CREDENTIALS_KEY`: generate with `mix ircpipe.gen_credentials_key` and retain for the lifetime of the encrypted data.
- `PHX_HOST`: public HTTPS hostname.

`PORT` defaults to `4000`; Railway supplies it automatically. `POOL_SIZE` defaults to `10`. OAuth, SMTP, Web Push, and discovery variables are optional and documented in `env.example`.

The image runs as an unprivileged user. It exposes `/health`, which returns HTTP 200 only when Phoenix can query PostgreSQL. The image-level health check calls that endpoint. Combined mode needs no Erlang node name, cookie, engine-node hostname, or clustering variable.

## Railway and similar container platforms

Railway detects the repository `Dockerfile`. Configure exactly one service replica with:

- Pre-deploy command: `/app/bin/migrate`
- Start command: `/app/bin/server`
- Health-check path: `/health`
- Health-check timeout: `300` seconds

Attach a managed PostgreSQL service or provide an external `DATABASE_URL`, then add the other required application variables above. The Docker build consumes Railway's `RAILWAY_GIT_COMMIT_SHA` so the OTP release version identifies the deployed source revision. Railway's health probe reaches `/health` directly over its private HTTP path; production SSL redirection excludes only that readiness path while normal browser requests still redirect to HTTPS.

Railway's repository-level `railway.toml` and `railway.json` configuration is deprecated and stops being read on 2026-12-01. Its replacement, `.railway/railway.ts`, owns the complete linked Railway project; omitted services and databases are deletion candidates. Run `railway config pull` against the real project before adopting Infrastructure as Code, add the four settings above to the imported application service, review `railway config plan`, and only then apply it. This repository intentionally does not provide a project-blind IaC file.

## VPS installation with Docker Compose

The production Compose package binds the application to `127.0.0.1:4000` by default and does not publish PostgreSQL. Put an HTTPS reverse proxy such as Caddy, nginx, or Traefik on the same host and proxy to that loopback address. If the proxy runs on another machine, set `IRCPIPE_BIND_IP` to a private interface and restrict the port with the host firewall; never expose it indiscriminately.

On a clean VPS with Git, Docker Engine, and the Compose plugin:

```bash
git clone <your-ircpipe-repository> /srv/ircpipe/source
cd /srv/ircpipe/source
cp env.example .env
```

Set every required value in `.env`, especially a strong `POSTGRES_PASSWORD`, and choose a persistent absolute host path. Compose passes the password as a discrete PostgreSQL setting rather than embedding it in a URL, so reserved URL characters are supported:

```text
IRCPIPE_POSTGRES_DATA=/srv/ircpipe/postgres
IRCPIPE_BIND_IP=127.0.0.1
IRCPIPE_PORT=4000
```

Create that directory with ownership appropriate for the PostgreSQL container, validate the resolved configuration, and start the stack:

```bash
docker compose --env-file .env -f docker-compose.prod.yml config --quiet
docker compose --env-file .env -f docker-compose.prod.yml up -d --build
docker compose --env-file .env -f docker-compose.prod.yml ps
curl --fail http://127.0.0.1:4000/health
```

The application waits for PostgreSQL health, runs migrations, and then starts the combined release. Keep exactly one `app` container.

## Back up and restore PostgreSQL

Create logical backups outside `IRCPIPE_POSTGRES_DATA`; copying the live data directory is not a safe backup procedure:

```bash
docker compose --env-file .env -f docker-compose.prod.yml exec -T postgres \
  pg_dump -U postgres -d ircpipe_prod -Fc > ircpipe-$(date +%Y%m%d-%H%M%S).dump
```

Test restores on another PostgreSQL instance regularly. Restoring over the production database is destructive: stop the application, preserve a second current backup, recreate or clean the target database, restore with `pg_restore`, and start the application only after `pg_restore` succeeds. For example, against an already empty `ircpipe_prod` database:

```bash
docker compose --env-file .env -f docker-compose.prod.yml stop app
docker compose --env-file .env -f docker-compose.prod.yml exec -T postgres \
  pg_restore -U postgres -d ircpipe_prod --exit-on-error < ircpipe-backup.dump
docker compose --env-file .env -f docker-compose.prod.yml up -d app
```

## Upgrade and rollback

Fetch and check out an exact commit rather than deploying a moving working tree. Build the image and run migrations before replacing the running application:

```bash
git fetch --all --prune
git checkout <exact-commit>
SOURCE_REVISION=$(git rev-parse HEAD) \
  docker compose --env-file .env -f docker-compose.prod.yml build app
docker compose --env-file .env -f docker-compose.prod.yml run --rm app /app/bin/migrate
docker compose --env-file .env -f docker-compose.prod.yml up -d --no-deps app
curl --fail http://127.0.0.1:4000/health
```

If migration fails, do not replace the running application. Investigate and either fix forward or restore the tested database backup; never mark a failed migration as applied manually.

For an application rollback, check out the prior exact commit, rebuild it, and replace only the `app` service. Roll back only when that release is compatible with every migration already applied. Additive migrations are normally compatible; destructive schema changes require a coordinated recovery plan. A database rollback uses the tested restore procedure above and causes downtime.
