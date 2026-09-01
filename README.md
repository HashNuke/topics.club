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
platforms. From a clone of the repository, with Docker Compose and OpenSSL:

```bash
bin/setup-compose
docker compose up -d --build
```

Open [localhost:4000](http://localhost:4000). The setup helper generates every
required secret and never changes an existing `.env`. For a public installation,
pass its hostname as `bin/setup-compose chat.example.com`, then follow the
[Compose deployment guide](docs/deployment.md#vps-installation-with-docker-compose)
for HTTPS, Google OAuth, Web Push, backups, and upgrades.

Compose runs migrations automatically and stores PostgreSQL data in the named
`postgres_data` volume. Do not run `docker compose down --volumes` unless you
intend to delete that database.

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
