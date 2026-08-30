# Deploy separate gateway and engine nodes to one VPS

This is the supported pyinfra topology: one Ubuntu 26.04 x86-64 VPS, one PostgreSQL
instance, and separate gateway and engine systemd services. Do not use two VPSs or run
more than one engine.

## 1. Prepare DNS and the host

- Point the public hostname to the VPS.
- Permit inbound SSH, HTTP, and HTTPS only. Do not expose ports `4000`, `4369`, `4370`,
  `4371`, or `5432`.
- Ensure `root@IP` is reachable with an SSH key.
- On your workstation, install `git` and `uv`, then use a clean clone of this repository.

Configure Google OAuth with this callback URL:

```text
https://YOUR_HOST/auth/google/callback
```

## 2. Provision PostgreSQL

From the repository root on your workstation:

```bash
bin/apptools provision-db --host root@YOUR_SERVER_IP
```

This installs PostgreSQL, creates `topics_club_prod` owned by `topics_club`, and generates
`/etc/topics-club/db.env`. Do not create or copy `DATABASE_URL` yourself.

## 3. Generate application secrets

Run locally and retain the results in your password manager:

```bash
mix phx.gen.secret
mix topics_club.gen_credentials_key
mix topics_club.gen_vapid_keys
openssl rand -hex 32
```

The last value is `RELEASE_COOKIE`. Use the same `IRC_CREDENTIALS_KEY` and
`RELEASE_COOKIE` for both services.

## 4. Create the application environment files

Open an SSH session:

```bash
ssh root@YOUR_SERVER_IP
install -d -m 0755 /etc/topics-club
install -m 0600 /dev/null /etc/topics-club/gateway.env
install -m 0600 /dev/null /etc/topics-club/engine.env
editor /etc/topics-club/gateway.env
```

Enter:

```dotenv
IRC_CREDENTIALS_KEY=...
RELEASE_COOKIE=...
SECRET_KEY_BASE=...
GATEWAY_HOST=YOUR_HOST
GOOGLE_CLIENT_ID=...
GOOGLE_CLIENT_SECRET=...
VAPID_PUBLIC_KEY=...
VAPID_PRIVATE_KEY=...
VAPID_SUBJECT=notifications@YOUR_HOST
ENABLE_DISCOVERY=false
RELEASE_NODE=topics_club_gateway@localhost
```

Then edit the engine file:

```bash
editor /etc/topics-club/engine.env
```

Enter:

```dotenv
IRC_CREDENTIALS_KEY=...
RELEASE_COOKIE=...
RELEASE_NODE=topics_club_engine@localhost
```

Exit SSH. Never commit or copy these filled files into the repository.

## 5. Provision the application host

```bash
bin/apptools provision --host root@YOUR_SERVER_IP
```

## 6. Tag and deploy

```bash
bin/release
git push origin THE_TAG_PRINTED_ABOVE
bin/apptools deploy --host root@YOUR_SERVER_IP --tag THE_TAG_PRINTED_ABOVE
```

## 7. Add HTTPS

Configure a reverse proxy on the VPS to terminate HTTPS and proxy the public hostname to
`http://127.0.0.1:4000`. For example, the Caddy site block is:

```caddyfile
YOUR_HOST {
  reverse_proxy 127.0.0.1:4000
}
```

## 8. Verify

```bash
ssh root@YOUR_SERVER_IP \
  'systemctl --no-pager status topics-club-gateway topics-club-engine'
curl --fail https://YOUR_HOST/health
```

## Later deployments

```bash
bin/release
git push origin THE_TAG_PRINTED_ABOVE
bin/apptools deploy --host root@YOUR_SERVER_IP --tag THE_TAG_PRINTED_ABOVE
```

Gateway-only deploys preserve IRC sessions:

```bash
bin/apptools deploy gateway --host root@YOUR_SERVER_IP --tag THE_TAG
```

See `docs/deployment.md` for rollback, health semantics, and operational details.
