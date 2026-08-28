# Ircpipe

To start your Phoenix server:

  * Run `mix setup` to install and setup dependencies
  * Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.

## What this app does

Ircpipe is a web-based IRC client. Users register or sign in, connect to arbitrary IRC networks, join channels, and chat from a React client backed by Phoenix JSON APIs and Phoenix Channels.

The backend persists channel messages for a short configurable window. Each user can choose 1, 2, or 3 days of scrollback. The authenticated user socket carries in-app updates; mention browser notifications are delivered only through Web Push. Users can mute mentions per server and per channel.

IRC connections are modeled as one supervised process per user/server connection under `Ircpipe.Irc.SessionSupervisor`.

## OAuth sign in

Google OAuth is configured through Ueberauth. Set these environment variables before starting the server:

```bash
export GOOGLE_CLIENT_ID="..."
export GOOGLE_CLIENT_SECRET="..."
```

Use this callback URL in the Google OAuth client:

```text
http://localhost:4100/auth/google/callback
```

For development and test, Ircpipe also exposes `/auth/developer`, a local Ueberauth strategy similar to OmniAuth's developer strategy. It presents a simple name/email form and signs in without calling an external provider. This provider is not configured in production.

In production, the Google sign-in button is shown only when both `GOOGLE_CLIENT_ID`
and `GOOGLE_CLIENT_SECRET` are set. Email registration and magic-link login need
SMTP configuration so the app can deliver confirmation and login links.

## Self-hosting with Docker

Ircpipe ships a Phoenix release Dockerfile and a production Compose file. The app
uses PostgreSQL in production; SQLite is not a runtime option because the repo is
compiled with `Ecto.Adapters.Postgres` and the dependency set includes `postgrex`.
Adding SQLite later would mean adding a second adapter dependency, changing repo
configuration, and testing migrations and queries against both databases.

Run exactly one Ircpipe app container/replica. IRC session ownership is
intentionally node-local, and the app disables its IRC session subsystem while
another visible BEAM node is connected. Do not horizontally scale the app until
database-backed session ownership leases and fencing are implemented.

The complete combined-mode runbook covers Railway settings, a clean VPS install,
safe reverse-proxy binding, backups, restores, upgrades, migration failures, and
rollback in [`docs/deployment.md`](docs/deployment.md).

Create a `.env` file from the example and set the required values:

```bash
cp env.example .env
mix phx.gen.secret
```

At minimum, set:

```text
PHX_HOST=your-host.example.com
TOPICS_CLUB_POSTGRES_DATA=/srv/ircpipe/postgres
POSTGRES_PASSWORD=use-a-long-random-password
SECRET_KEY_BASE=the-value-from-mix-phx-gen-secret
IRC_CREDENTIALS_KEY=the-value-from-32-random-bytes-encoded-with-base64
```

Generate `IRC_CREDENTIALS_KEY` with `mix topics_club.gen_credentials_key`.

Discovery refresh workers start automatically in development. They are disabled
by default in production; set `ENABLE_DISCOVERY=true` on only the deployment that
should fetch the Netsplit server catalog and IRC channel lists.

### Mention push notifications

Generate a VAPID keypair once per deployment and keep the private key secret:

```bash
mix topics_club.gen_vapid_keys
```

Copy the generated `VAPID_PUBLIC_KEY` and `VAPID_PRIVATE_KEY` into `.env`. Set
`VAPID_SUBJECT` to the plain contact email address for the deployment; Ircpipe
adds the required `mailto:` prefix. Push setup is unavailable in the UI until all
three values are configured.

Web Push requires HTTPS in production (browsers allow localhost for development).
The service worker only shows notifications when no visible Ircpipe window is
open. Delivery jobs are persisted in PostgreSQL through Oban and retried for
temporary push-service failures. Subscription endpoints and browser keys are
encrypted at rest using `IRC_CREDENTIALS_KEY`.

`TOPICS_CLUB_POSTGRES_DATA` is a host directory that you choose. Compose bind-mounts
it to `/var/lib/postgresql/data`, so that directory is where all database data is
stored.

Start the production stack:

```bash
docker compose --env-file .env -f docker-compose.prod.yml up -d --build
```

The app container waits for Postgres, runs migrations, and then starts Phoenix on
container port `4000`. It binds host loopback by default; set `TOPICS_CLUB_PORT` to
choose the host port and change `TOPICS_CLUB_BIND_IP` only when a reverse proxy on a
private network cannot reach loopback.

The Docker build uses this repository as its build context and fetches the
`ircxd` dependency from GitHub. For a manual image build, run this from the
repository root:

```bash
docker build .
```

### Self-hosted auth

For a private self-hosted instance, the simplest production setup is:

```text
SMTP_RELAY=smtp.example.com
SMTP_PORT=587
SMTP_USERNAME=...
SMTP_PASSWORD=...
SMTP_TLS=if_available
EMAIL_FROM_ADDRESS=ircpipe@example.com
```

With SMTP configured, users can register and log in by email magic link, then set
a password from account settings. If you prefer OAuth-only sign-in, configure
`GOOGLE_CLIENT_ID` and `GOOGLE_CLIENT_SECRET` instead. The development-only
`/auth/developer` provider is intentionally not enabled in production.

## Local database

The generated dev/test config expects PostgreSQL on `localhost:5432` with username/password `postgres`/`postgres`. A `docker-compose.yml` is included for that database:

```bash
docker compose up -d postgres
mix setup
mix phx.server
```

`mix setup` also seeds suggested topics for the local development InspIRCd server
at `127.0.0.1:6669` and then tries to join those channels once with `ircxd` so
they are ready for manual testing. If InspIRCd is not running yet, setup
continues and the channels will still be created when users join them from the
app.

Populate any due Discover data manually with:

```bash
mix topics_club.refresh_discovery
```

Production checks automatically every hour. It refreshes the IRC network catalog
from Netsplit after seven days and obtains each network's server channels, topics,
and visible user counts through IRC `LIST` after 24 hours.

The repo includes a systemd unit for this development IRC server:

```bash
sudo install -m 0644 dev/systemd/irc-server-dev.service /etc/systemd/system/irc-server-dev.service
sudo install -m 0644 dev/inspircd/inspircd.conf /etc/inspircd/ircpipe-dev.conf
sudo install -m 0644 dev/inspircd/inspircd.motd /etc/inspircd/ircpipe-dev.motd
sudo systemctl daemon-reload
sudo systemctl enable --now irc-server-dev.service
```

This intentionally avoids the default IRC port `6667`, which is left free for
`ircxd` builds and tests.

Ready to run in production? Please [check our deployment guides](https://hexdocs.pm/phoenix/deployment.html).

## Learn more

* Official website: https://www.phoenixframework.org/
* Guides: https://hexdocs.pm/phoenix/overview.html
* Docs: https://hexdocs.pm/phoenix
* Forum: https://elixirforum.com/c/phoenix-forum
* Source: https://github.com/phoenixframework/phoenix
