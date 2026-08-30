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
bin/apptools provision --host root@YOUR_SERVER_IP --gateway_host=YOUR_HOST
```

Supplying `--gateway_host` also installs Caddy, obtains HTTPS certificates, redirects the
`www` hostname to the root hostname, and enables a host firewall with rules for the SSH
connection port plus HTTP and HTTPS. Application, Erlang distribution, and PostgreSQL ports
remain loopback-only. Audit any pre-existing firewall rules separately; provisioning does not
silently delete operator-managed rules.

The default HTTPS repository URL works once the repository is public. For a private GitHub
repository, provision with its SSH URL instead:

```bash
bin/apptools provision --host root@YOUR_SERVER_IP \
  --gateway_host=YOUR_HOST \
  --repository=git@github.com:OWNER/REPOSITORY.git
ssh root@YOUR_SERVER_IP \
  'cat /srv/topics-club/build-home/.ssh/id_ed25519.pub'
```

Add the printed public key to that repository under **Settings → Deploy keys** without write
access, then continue. The private key is generated on and never leaves the destination;
GitHub's published Ed25519 host key is pinned during provisioning.

## 6. Tag and deploy

```bash
bin/release
git push origin THE_TAG_PRINTED_ABOVE
bin/apptools deploy --host root@YOUR_SERVER_IP --tag THE_TAG_PRINTED_ABOVE
```

## 7. Confirm HTTPS

Provisioning configures Caddy to terminate HTTPS and proxy to `127.0.0.1:4000`. Confirm
that Caddy obtained certificates before verification:

```bash
ssh root@YOUR_SERVER_IP 'systemctl --no-pager status caddy'
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
