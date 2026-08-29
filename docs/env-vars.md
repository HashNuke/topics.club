# Environment variables by deployment

Environment variables fall into three groups: essential application
configuration, deployment wiring, and optional features. Start with the small
essential set and ignore the other groups unless the selected deployment needs
them.

## Essential production configuration

The combined application used by Railway needs these nine values:

```text
DATABASE_URL=ecto://user:password@database-host/topics_club_prod
SECRET_KEY_BASE=replace-with-mix-phx-gen-secret-output
IRC_CREDENTIALS_KEY=replace-with-generated-credentials-key
GATEWAY_HOST=topics.club
GOOGLE_CLIENT_ID=replace-with-google-client-id
GOOGLE_CLIENT_SECRET=replace-with-google-client-secret
VAPID_PUBLIC_KEY=replace-with-generated-public-key
VAPID_PRIVATE_KEY=replace-with-generated-private-key
VAPID_SUBJECT=notifications@example.com
```

- `DATABASE_URL` tells the application how to reach PostgreSQL.
- `SECRET_KEY_BASE` signs and encrypts web sessions and cookies.
- `IRC_CREDENTIALS_KEY` encrypts stored IRC credentials. Retain it for the
  lifetime of the encrypted data.
- `GATEWAY_HOST` is the public hostname without a scheme or path. For example,
  `topics.club` produces the Google callback URL
  `https://topics.club/auth/google/callback`.
- `GOOGLE_CLIENT_ID` and `GOOGLE_CLIENT_SECRET` enable Google sign-in.
- `VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY`, and `VAPID_SUBJECT` authorize Web
  Push notifications. Generate the key pair with
  `mix topics_club.gen_vapid_keys`; the subject is the deployment contact email.

Railway supplies `PORT` and normally supplies `DATABASE_URL` through its
PostgreSQL service. The Docker image supplies the release startup settings.

The pyinfra deployment uses the same application values, but splits the gateway
and engine into two services. Its destination-only environment files also carry
the Erlang distribution cookie and node wiring described below.

The root `env.example` is specifically the template for production Docker
Compose. It is not the environment template for local development, the
pyinfra-managed split deployment, or Railway.

| Variable group | Development | Docker Compose | Pyinfra direct host | Railway |
|---|---:|---:|---:|---:|
| `GATEWAY_HOST` | No; dev is hard-coded | Yes | Gateway | Yes |
| `TOPICS_CLUB_BIND_IP`, `TOPICS_CLUB_PORT` | No | Compose only | No | No |
| `TOPICS_CLUB_POSTGRES_DATA`, `POSTGRES_PASSWORD` | No | Compose/Postgres only | No | No |
| `SOURCE_REVISION` | No | Optional build override | No; deploy tooling supplies it | No; Railway supplies Git SHA |
| `SECRET_KEY_BASE` | No; dev has a fixed key | App container | Gateway | Yes |
| `IRC_CREDENTIALS_KEY` | No; dev has a fixed key | App container | Gateway **and** engine | Yes |
| `POOL_SIZE`, `DB_QUEUE_TARGET`, `DB_QUEUE_INTERVAL` | No | Optional tuning | Gateway and engine | Optional tuning |
| `ENABLE_DISCOVERY` | Dev enables it automatically | Defaults to `false` | Gateway; defaults to `false` | Defaults to `false` |
| `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET` | Optional | App container | Gateway | Yes |
| `VAPID_*` | Optional | App container | Gateway | Yes |

## Settings that normally need no attention

- `PORT` defaults to `4000`; Railway supplies it automatically.
- `POOL_SIZE`, `DB_QUEUE_TARGET`, and `DB_QUEUE_INTERVAL` have production
  defaults (`10`, `5000`, and `5000`, respectively). Do not set them during a
  normal installation; override them only when intentionally tuning database
  concurrency and checkout behavior.
- `ENABLE_DISCOVERY` defaults to `false` in production. Set it to `true` only on
  the one gateway that should refresh IRC discovery data.

## Source revision metadata

`SOURCE_REVISION` exists only while building a release. It identifies the source
used for the artifact, becomes the suffix in an OTP release version such as
`0.1.0+05b90f1abc12`, and lets deployment and rollback tooling relate an artifact
to its source commit. It does not change application behavior and is not read
when the application starts.

- Pyinfra resolves the selected release tag to an exact Git commit and supplies
  that commit automatically while building both split releases. It also records
  the full commit in each deployment manifest.
- Railway supplies `RAILWAY_GIT_COMMIT_SHA`; the Dockerfile uses it
  automatically.
- Docker Compose permits an optional `SOURCE_REVISION` build override. When it
  is absent, the Dockerfile computes a deterministic digest of the copied source
  tree instead.
- Development does not use it. CI supplies source revision metadata directly
  when verifying release assembly.

Operators normally should not set `SOURCE_REVISION` in any environment.

## Deployment-only settings

Docker Compose alone uses `TOPICS_CLUB_BIND_IP`, `TOPICS_CLUB_PORT`,
`TOPICS_CLUB_POSTGRES_DATA`, and `POSTGRES_PASSWORD` to configure its host port
and bundled PostgreSQL container. They are not application configuration.

The pyinfra split deployment uses `RELEASE_NODE`, `RELEASE_COOKIE`, and, on the
gateway, `TOPICS_CLUB_ENGINE_NODE` so its two BEAM nodes can communicate. Use
`tools/deploy/gateway.env.example` and `tools/deploy/engine.env.example` as the
lists for those destination-only files.

## Deployment shapes

- **Development** runs the combined application through Mix. Its endpoint,
  database credentials, application secrets, and discovery behavior have
  development configuration in `config/dev.exs`. Elixir does not automatically
  load the root `.env` file.
- **Docker Compose** runs one combined `topics_club` application container, with
  the gateway and IRC engine in the same BEAM node. PostgreSQL runs in a separate
  container. This is the same application topology as Railway.
- **Pyinfra direct host** runs the split `topics_club_gateway` and
  `topics_club_engine` releases as two systemd services on one host. Use
  `tools/deploy/gateway.env.example` and `tools/deploy/engine.env.example`, not
  the root `env.example`. PostgreSQL is provisioned separately.
- **Railway** builds the repository `Dockerfile` and runs one combined
  `topics_club` application instance. Railway supplies `PORT` and
  `RAILWAY_GIT_COMMIT_SHA`; its PostgreSQL service normally supplies
  `DATABASE_URL`.

All production variants must run exactly one IRC engine. Do not scale the
combined Docker Compose or Railway application beyond one replica.
