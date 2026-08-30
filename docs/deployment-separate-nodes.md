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

Install and sign in to the 1Password CLI. In the `app-secrets` vault, create a Secure Note
named `topics-club-prod` with `shared` and `gateway` sections. Then run:

```bash
bin/apptools create-secrets --env prod
```

The command fills only empty or missing `IRC_CREDENTIALS_KEY`, `RELEASE_COOKIE`,
`SECRET_KEY_BASE`, `VAPID_PUBLIC_KEY`, and `VAPID_PRIVATE_KEY` fields. It never prints or
replaces their values. Add the remaining gateway values to the note manually.
Use `--env dev` to target `app-secrets/topics-club-dev` instead.

To copy all application values as ready-to-paste `KEY=value` lines without displaying
them in the terminal:

```bash
bin/apptools copy-secrets --env prod
```

This uses `pbcopy` on macOS and supports `wl-copy`, `xclip`, or `xsel` on Linux. It omits
the destination-generated `DATABASE_URL` and component-specific `RELEASE_NODE`.

## 4. Install the application environment files

While signed in to the 1Password CLI locally, run:

```bash
bin/apptools deploy install-secrets --env prod --host root@YOUR_SERVER_IP
```

This reads `app-secrets/topics-club-prod` into memory and streams role-specific files over
encrypted SSH to `/etc/topics-club/gateway.env` and `/etc/topics-club/engine.env` with mode
`0600`. It creates no local plaintext file and does not print the values. The files get stable
role-specific `RELEASE_NODE` values; `DATABASE_URL` remains in the separately generated `db.env`.

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
