# Development

## Quick start

The known-good development toolchain is Elixir 1.19 with Erlang/OTP 28, Node.js
24 with npm, and PostgreSQL 16. Docker is the quickest way to supply only the
database.

```bash
git clone https://github.com/HashNuke/topics.club.git
cd topics.club
docker compose -p topics-club-dev -f docker-compose.dev.yml up -d postgres
npm ci --prefix apps/topics_club_gateway/assets
mix setup
mix phx.server
```

Open [localhost:4100](http://localhost:4100). Development includes a local
developer sign-in, so Google credentials are not required.

`mix setup` seeds a few topics for the optional development IRC server at
`127.0.0.1:6669`. If that server is absent, setup prints a warning and continues;
you can still connect the app to any reachable IRC network.

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

After changing the seeded topics, run `mix topics_club.setup_local_irc` again to
create or update their local channels.

Port `6667` remains free for `ircxd` builds and tests.
