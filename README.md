<div align="center">
  <h1><img src="docs/assets/topics-club-wordmark.svg" alt="topics.club" width="420" /></h1>

  <h3>A friendly, self-hostable web client for IRC.</h3>

  <p>
    Join channels on public IRC networks or your own private server,<br />
    directly from the browser.
  </p>

  <p>
    <a href="#choose-how-to-run-it">Run it</a> ·
    <a href="docs/env-vars.md">Environment variables</a> ·
    <a href="docs/deployment.md">Deployment guide</a>
  </p>

  <!-- Replace TOPICS_CLUB_TEMPLATE_CODE after publishing the Railway template. -->
  <p>
    <a href="https://railway.com/new/template/TOPICS_CLUB_TEMPLATE_CODE?utm_medium=integration&utm_source=button&utm_campaign=topics-club"><img src="https://railway.com/button.svg" alt="Deploy on Railway" width="183" height="40" /></a>
  </p>

  <p><code>Phoenix 1.8</code> · <code>React 19</code> · <code>PostgreSQL</code> · <code>IRC</code></p>
</div>

## IRC in the browser, on your terms

`topics.club` gives IRC a focused, responsive web interface. Use it with public
networks, or self-host it alongside an IRC server you control for a private team
space. New users get a straightforward path into channels, while experienced
users retain direct server connections and IRC interoperability.

- Browse featured channels across multiple IRC networks.
- Connect directly to arbitrary public or private IRC servers and channels.
- Keep several server connections and channels open at once.
- Get realtime chat, mention indicators, and optional Web Push notifications.
- Retain a private, per-user window of one to three days of scrollback.
- Self-host the client and pair it with an IRC server your team controls.

## Choose how to run it

| Path | Best for | What it runs |
| --- | --- | --- |
| [**Direct development**](docs/development.md#quick-start) | Exploring the product or contributing code | Phoenix directly on your machine, with PostgreSQL locally or in Docker |
| [**Docker Compose**](docs/deployment.md#vps-installation-with-docker-compose) | A simple self-hosted installation | One production application container and one private PostgreSQL container |
| [**Railway**](docs/deployment.md#railway-and-similar-container-platforms) | A managed deployment from GitHub | One application service and managed PostgreSQL |

An advanced, first-party split topology is also available for deployments where
the web gateway and IRC engine need independent release lifecycles. Start with
the combined app unless you specifically need that separation; the
[split deployment guide](docs/deployment-separate-nodes.md) covers the supported
single-host setup.

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

## Configuration and deployment

- [Development](docs/development.md) — optional services and richer local IRC
  testing.
- [Environment variables](docs/env-vars.md) — required values, optional
  features, deployment-specific placement, and database tuning.
- [Combined deployment](docs/deployment.md) — Railway, Docker Compose, health,
  logs, backup/restore, upgrades, migration failures, and rollback.
- [Split deployment](docs/deployment-separate-nodes.md) — the advanced
  gateway/Wirekeeper/engine topology on one VPS.
- [Load testing](docs/load-tests.md) — the repeatable burst and connection-load
  scenarios used to tune the database queue.
