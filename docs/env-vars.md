# Environment variables

Start with the production variables below. The later sections contain only
deployment-specific wiring and advanced tuning.

Minimal placeholder files are available at `samples/app.env.dev.sample`,
`samples/gateway.env.prod.sample`, and `samples/engine.env.prod.sample`. The two
production samples match the pyinfra split roles. They contain no tuning knobs.
Elixir does not load these files automatically; export their values through the
shell or deployment platform.

## Production application configuration

| Variable | Purpose |
| --- | --- |
| `DATABASE_URL` | PostgreSQL connection URL. Railway supplies it; the bare-host database command generates it. |
| `SECRET_KEY_BASE` | Signs and encrypts web sessions and cookies. Generate it with `mix phx.gen.secret`. |
| `IRC_CREDENTIALS_KEY` | Encrypts stored IRC credentials. Generate it with `mix topics_club.gen_credentials_key` and retain it for the lifetime of the encrypted data. |
| `GATEWAY_HOST` | Public hostname without a scheme or path, such as `topics.club`. |
| `GOOGLE_CLIENT_ID` | Google OAuth client ID. |
| `GOOGLE_CLIENT_SECRET` | Google OAuth client secret. |
| `VAPID_PUBLIC_KEY` | Public Web Push application key. |
| `VAPID_PRIVATE_KEY` | Private Web Push signing key. |
| `VAPID_SUBJECT` | Web Push contact email, such as `notifications@example.com`. |

Generate the VAPID values with `mix topics_club.gen_vapid_keys`.
`GATEWAY_HOST=topics.club` produces the Google callback URL
`https://topics.club/auth/google/callback`.

## Where the production variables go

| Variable group | Docker Compose | Pyinfra direct host | Railway |
| --- | --- | --- | --- |
| `DATABASE_URL` | Compose configures its bundled database internally | Generated in `/etc/topics-club/db.env` and loaded by both services | Supplied by the PostgreSQL service |
| `SECRET_KEY_BASE`, `GATEWAY_HOST` | App container | Gateway | App service |
| `IRC_CREDENTIALS_KEY` | App container | Gateway and engine | App service |
| `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET` | App container | Gateway | App service |
| `VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY`, `VAPID_SUBJECT` | App container | Gateway | App service |

Docker Compose and Railway run the combined gateway and engine in one
application instance. Pyinfra runs separate gateway and engine services on one
host. Every production topology must run exactly one IRC engine.

## Development

Local development already defines its database, port, and development secrets
in `config/dev.exs`. It does not load the root `.env` automatically.

The developer OAuth provider needs no environment variables. Set
`GOOGLE_CLIENT_ID` and `GOOGLE_CLIENT_SECRET` locally only when testing Google
OAuth. VAPID variables are needed locally only when testing Web Push.

## Optional application settings

| Variable | Default | Purpose |
| --- | --- | --- |
| `ENABLE_DISCOVERY` | `false` in production | Set to `true` on the one gateway that should periodically refresh IRC discovery data. Development enables discovery automatically. |
| `PORT` | `4000` | Internal HTTP port. Railway supplies it automatically. |

## Deployment-only settings

These settings are not shared application configuration.

### Docker Compose

The root `env.example` is only for production Docker Compose. In addition to the
production application values, Compose uses:

| Variable | Purpose |
| --- | --- |
| `POSTGRES_PASSWORD` | Password for the bundled PostgreSQL container. |

PostgreSQL data is stored in the Compose-managed `postgres_data` volume. The
application is published at `127.0.0.1:4000`; use a Compose override when a
different host interface or port is required.

### Pyinfra split deployment

Use `tools/deploy/gateway.env.example` and
`tools/deploy/engine.env.example` for the destination-only files. The split
runtime additionally needs the following application settings:

| Variable | Used by | Purpose |
| --- | --- | --- |
| `RELEASE_NODE` | Gateway and engine | Stable internal name of each BEAM node. |
| `RELEASE_COOKIE` | Gateway and engine | Shared secret for Erlang distribution. Use the same value in both files. |

The gateway automatically connects to `topics_club_engine@localhost`.
Run `bin/apptools provision-db --host root@IP` before application provisioning.
It installs PostgreSQL 18, creates the database and role, and generates the
shared `DATABASE_URL` in root-owned `/etc/topics-club/db.env`. Operators do not
create or copy this file, and normal application env files do not repeat the URL.

## Advanced database tuning

Normal installations should not set these variables. The application defaults
are intended for ordinary production use.

| Variable | Default | Purpose |
| --- | ---: | --- |
| `POOL_SIZE` | `10` | Number of database connections opened by each application service. |
| `DB_QUEUE_TARGET` | `5000` ms | Ecto checkout queue target. TopicsClub raised this default after load tests showed that short synchronized IRC bursts could otherwise exhaust the checkout queue. |
| `DB_QUEUE_INTERVAL` | `5000` ms | Interval over which Ecto evaluates checkout pressure. |

Override these only after measuring the application and PostgreSQL under the
actual production workload.
