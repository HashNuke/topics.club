# Ircpipe

To start your Phoenix server:

  * Run `mix setup` to install and setup dependencies
  * Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.

## What this app does

Ircpipe is a web-based IRC client. Users register or sign in, connect to arbitrary IRC networks, join channels, and chat from a React client backed by Phoenix JSON APIs and Phoenix Channels.

The backend persists channel messages for a short configurable window. Each user can choose 1, 2, or 3 days of scrollback. Mention notifications are delivered over the authenticated user socket; the React client shows mention counts in the sidebar while the app is visible and browser notifications while it is in the background.

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

Create a `.env` file from the example and set the required values:

```bash
cp .env.example .env
mix phx.gen.secret
```

At minimum, set:

```text
PHX_HOST=your-host.example.com
IRCPIPE_POSTGRES_DATA=/srv/ircpipe/postgres
POSTGRES_PASSWORD=use-a-long-random-password
SECRET_KEY_BASE=the-value-from-mix-phx-gen-secret
IRC_CREDENTIALS_KEY=the-value-from-32-random-bytes-encoded-with-base64
```

Generate `IRC_CREDENTIALS_KEY` with
`mix run -e 'IO.puts(32 |> :crypto.strong_rand_bytes() |> Base.encode64())'`.

`IRCPIPE_POSTGRES_DATA` is a host directory that you choose. Compose bind-mounts
it to `/var/lib/postgresql/data`, so that directory is where all database data is
stored.

Start the production stack:

```bash
docker compose --env-file .env -f docker-compose.prod.yml up -d --build
```

The app container waits for Postgres, runs migrations, and then starts Phoenix on
container port `4000`. Set `IRCPIPE_PORT` to choose the host port.

Because `ircpipe` currently depends on the sibling `../ircxd` package, the
Dockerfile is built with the parent directory as context. Compose handles this
automatically. For a manual image build, run this from the parent directory:

```bash
docker build -f ircpipe/Dockerfile .
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
