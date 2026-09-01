<div align="center">
  <h1><img src="docs/assets/topics-club-wordmark.svg" alt="topics.club" width="420" /></h1>

  <h3>Topic-first community discovery, powered by IRC.</h3>

  <p>
    Find an interesting conversation, join it in one click, and keep the openness<br />
    of IRC without making newcomers configure a server first.
  </p>

  <p>
    <a href="#choose-how-to-run-it">Run it</a> ·
    <a href="docs/env-vars.md">Environment variables</a> ·
    <a href="docs/deployment.md">Deployment guide</a>
  </p>

  <p><code>Phoenix 1.8</code> · <code>React 19</code> · <code>PostgreSQL</code> · <code>IRC</code></p>
</div>

## IRC, without the scavenger hunt

`topics.club` is a responsive web IRC client built around conversations rather
than configuration. Its curated discovery page maps approachable topics to real
channels on open IRC networks. Newcomers can start with something that interests
them; experienced IRC users can still connect directly to arbitrary servers and
channels.

- Browse featured communities across multiple IRC networks.
- Keep several server connections and conversations open at once.
- Get realtime chat, mention indicators, and optional Web Push notifications.
- Retain a private, per-user window of one to three days of scrollback.
- Self-host a modern Phoenix and React application without giving up IRC
  interoperability.

## Choose how to run it

| Path | Best for | What it runs |
| --- | --- | --- |
| **Direct development** | Exploring the product or contributing code | Phoenix directly on your machine, with PostgreSQL locally or in Docker |
| **Docker Compose** | A simple self-hosted installation | One production application container and one private PostgreSQL container |
| **Railway** | A managed deployment from GitHub | One application service and managed PostgreSQL |

An advanced, first-party split topology is also available for deployments where
the web gateway and IRC engine need independent release lifecycles. Start with
the combined app unless you specifically need that separation; the
[split deployment guide](docs/deployment-separate-nodes.md) covers the supported
single-host setup.

> [!IMPORTANT]
> Run exactly one IRC engine. For Docker Compose and Railway, that means exactly
> one application container or replica. IRC session ownership is intentionally
> node-local and is not protected by partition-safe database fencing yet.

## Quick start: direct development

The known-good development toolchain is Elixir 1.19 with Erlang/OTP 28, Node.js
24 with npm, and PostgreSQL 16. Docker is the quickest way to supply only the
database.

```bash
git clone https://github.com/HashNuke/topics.club.git
cd topics.club
docker compose -p topics-club-dev up -d postgres
npm ci --prefix apps/topics_club_gateway/assets
mix setup
mix phx.server
```

Open [localhost:4100](http://localhost:4100). Development includes a local
developer sign-in, so Google credentials are not required.

`mix setup` seeds a few topics for the optional development IRC server at
`127.0.0.1:6669`. If that server is absent, setup prints a warning and continues;
you can still connect the app to any reachable IRC network. Instructions for the
local InspIRCd service are in the [development IRC section](#optional-local-irc-server).

## Quick start: Docker Compose

This path builds the same combined production release used by container
platforms. You need Git, Docker Engine, Docker Compose, and an HTTPS reverse
proxy for a public installation.

```bash
git clone https://github.com/HashNuke/topics.club.git
cd topics.club
cp env.example .env

# Generate values to paste into .env:
openssl rand -base64 48  # SECRET_KEY_BASE
openssl rand -base64 32  # IRC_CREDENTIALS_KEY
openssl rand -hex 32     # POSTGRES_PASSWORD
```

Edit `.env`, set `GATEWAY_HOST` to your public hostname, and replace the Google
OAuth placeholders if people should be able to sign in. Clear unused Google and
VAPID placeholders rather than leaving their example text in place. Then
validate and start the stack:

```bash
docker compose --env-file .env -f docker-compose.prod.yml config --quiet
docker compose --env-file .env -f docker-compose.prod.yml up -d --build
docker compose --env-file .env -f docker-compose.prod.yml ps
curl --fail http://127.0.0.1:4000/health
```

The app listens on `127.0.0.1:4000`; put Caddy, nginx, or Traefik in front of it
for public HTTPS. For a local landing-page smoke test, use
`GATEWAY_HOST=localhost` and open [localhost:4000](http://localhost:4000).

Compose runs migrations automatically and stores PostgreSQL data in the named
`postgres_data` volume. Do not run `docker compose down --volumes` unless you
intend to delete that database. The [deployment guide](docs/deployment.md#vps-installation-with-docker-compose)
covers reverse-proxy placement, backups, restores, upgrades, and rollback.

## Quick start: Railway

1. Create a Railway project from this GitHub repository. Railway detects the
   root `Dockerfile` automatically.
2. Add a PostgreSQL service, then add its `DATABASE_URL` to the application as a
   reference variable (usually `${{Postgres.DATABASE_URL}}`).
3. Give the application a public domain. Set `GATEWAY_HOST` to that hostname
   without `https://` or a path.
4. Add `SECRET_KEY_BASE`, `IRC_CREDENTIALS_KEY`, `GOOGLE_CLIENT_ID`, and
   `GOOGLE_CLIENT_SECRET` to the application service. Generate the two secrets
   with the commands from the Docker Compose section above.
5. Under the application's deploy settings, use:

   ```text
   Pre-deploy command    /app/bin/migrate
   Start command         /app/bin/server
   Health-check path     /health
   Health-check timeout  300 seconds
   Replicas              1
   ```

6. In Google Cloud, allow
   `https://<GATEWAY_HOST>/auth/google/callback`, then deploy.

Web Push is optional. Add `VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY`, and
`VAPID_SUBJECT` when you want browser mention notifications. See the
[Railway runbook](docs/deployment.md#railway-and-similar-container-platforms)
before adopting Railway Infrastructure as Code; the repository deliberately
does not ship project-blind Railway configuration.

## Configuration and deployment

- [Environment variables](docs/env-vars.md) — required values, optional
  features, deployment-specific placement, and database tuning.
- [Combined deployment](docs/deployment.md) — Railway, Docker Compose, health,
  logs, backup/restore, upgrades, migration failures, and rollback.
- [Split deployment](docs/deployment-separate-nodes.md) — the advanced
  gateway/Wirekeeper/engine topology on one VPS.
- [Load testing](docs/load-tests.md) — the repeatable burst and connection-load
  scenarios used to tune the database queue.

## For contributors

The repository is an Elixir umbrella: core data and policy live in
`apps/topics_club_core`, the IRC runtime in `apps/topics_club_engine`, the
Phoenix/React web app in `apps/topics_club_gateway`, and restart-resilient socket
ownership for the split deployment in `apps/topics_club_wirekeeper`.

Every project-owned React component is independently previewable in Storybook:

```bash
npm run storybook --prefix apps/topics_club_gateway/assets
```

Before opening a change, run the same complete check used by the project:

```bash
mix precommit
```

That compiles with warnings as errors, formats Elixir, type-checks and tests the
React frontend, builds Storybook, and runs the Elixir test suites.

## Optional local IRC server

The repository includes an InspIRCd configuration and a systemd unit for richer
local testing on port `6669`:

```bash
sudo install -m 0644 dev/systemd/irc-server-dev.service /etc/systemd/system/irc-server-dev.service
sudo install -m 0644 dev/inspircd/inspircd.conf /etc/inspircd/topics-club-dev.conf
sudo install -m 0644 dev/inspircd/inspircd.motd /etc/inspircd/topics-club-dev.motd
sudo systemctl daemon-reload
sudo systemctl enable --now irc-server-dev.service
mix topics_club.setup_local_irc
```

Port `6667` remains free for `ircxd` builds and tests.
