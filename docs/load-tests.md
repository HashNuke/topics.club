# Load tests

This document records the reproducible load labs, observations, and results for the standalone IRC
engine, the combined TopicsClub application, and the current split gateway, Wirekeeper, and engine
deployment. The older Docker results use the direct transport and remain a historical baseline; the
testvps result explicitly measures the split Wirekeeper transport.

## Safety boundary

The harness must never connect to a public IRC server or network.

- The synthetic IRC server is the `irc` service in `docker-compose.load-test.yml`.
- Every seeded connection uses the Docker hostname `irc` and port `6667` without TLS.
- The Compose network has `internal: true` and publishes no ports to the host.
- The app, load client, Postgres, and synthetic IRC server communicate only on that network.
- `docker compose -f docker-compose.load-test.yml config` should be inspected before changing
  the harness. Do not add public IRC hostnames to the seed data.

## What the lab measures

There are four deliberately separate measurements:

1. **Idle connection capacity** starts one IRC session per user, completes two-way IRC
   registration, persists the resulting server messages, and holds the sockets open.
2. **Engine workload** adds app-to-server messages with server echoes, server-to-app messages
   with marker-specific Postgres persistence checks, a full engine restart, and forced socket
   loss followed by reconnection.
3. **Combined application workload** keeps the IRC sessions in the normal combined production
   release while sending public health requests and authenticated `/api/bootstrap` requests.
   Authentication uses the real magic-link and signed-cookie flow; there is no load-test API in
   the production application.
4. **Split-release workload** runs gateway, Wirekeeper, and engine as separate systemd services,
   then distinguishes retained-socket engine resume from deliberate socket replacement and proves
   exact bidirectional traffic at the planning checkpoint.

The raw JSON from each run is written under `.load-tests/`, which is intentionally ignored by
Git. The committed document contains the stable conclusions so generated measurements do not
make the repository noisy.

## Lab configuration

Measurements in this report were taken on 2026-08-28 at source revision
`f452222e0c5fabcc53ad57b94149b2decbd566ed`, with uncommitted load-harness and tuning changes
described in this document. The final post-fix engine and combined images used source-tree digest
`cc7fe4ffef3cad36745fa166530a30dd300ef4a439c53dfae188ab6d58efe545`. The final image was used
for the 4,000-session workload, the 4,000/8,000/10,000 combined checkpoints, and repeat idle
checks at 8,000 and 15,000. Lower idle checkpoints and the 1,000-session combined baseline came
from source-tree digest `3263fc665de78f49541df70e02c6f649ea148c5065c7328e1f4b7ff1bccc1315`,
before the reconnect and database-queue fixes; the affected high-load checkpoints were repeated
after those fixes.

Host and container limits:

| Resource | Value |
| --- | ---: |
| Host | Linux 6.8, x86-64 |
| Docker | 29.4.1, overlayfs |
| Host CPU | 4 logical CPUs |
| Host memory | 8,126,685,184 bytes |
| Engine or combined app | 2 CPUs, 1.5 GiB, 65,536 file descriptors |
| Postgres 16 | 1 CPU, 768 MiB |
| Synthetic IRC server | 1 CPU, 768 MiB, 65,536 file descriptors |
| Ecto pool | 10 connections |
| Ecto queue target / interval | 5,000 ms / 5,000 ms |

The limits are part of the result. A different CPU count, memory limit, database, TLS workload,
kernel, or IRC behavior can produce a different capacity.

## Running it

Prerequisites are Docker with Compose and Python 3. The scripts use only Python's standard
library.

Build the production releases and run the default standalone capacity sweep:

```sh
python3 tools/load_test/run.py capacity
```

Reuse those images for a targeted sweep:

```sh
python3 tools/load_test/run.py --skip-build \
  --steady-seconds 20 \
  capacity --counts 1000,4000,8000
```

Run the bidirectional workload and recovery checks:

```sh
python3 tools/load_test/run.py --skip-build \
  workload --connections 4000 \
  --messages-per-connection 1 \
  --inbound-batch-size 4000 \
  --inbound-pause-ms 0
```

Run the combined release with authenticated HTTP traffic:

```sh
python3 tools/load_test/run_full_app.py \
  --counts 1000,4000,8000 \
  --http-requests 200 \
  --http-concurrency 20
```

The scripts reset only the Compose project named `topics-club-loadtest`, including its disposable
Postgres volume, before every scenario and on exit.

## Split-release testvps capacity runner

The current architecture has a separate explicit runner which exercises the production gateway,
Wirekeeper, and engine releases under systemd:

```sh
bin/apptools testvps load \
  --counts=100,500,1000,2000,3000,4000 \
  --batch_size=100 \
  --provision_concurrency=10 \
  --steady_seconds=300 \
  --sample_interval=5
```

Do not run it against a pseudo-VPS containing real or unrelated test connections. It refuses to
start unless the database, engine, Wirekeeper, and synthetic IRC server all have zero connections.
It also refuses a ramp whose maximum target would approach the deployed Wirekeeper service's soft
open-file limit; reprovisioned hosts set that limit to 65,536 so the operating-system default does
not create an artificial boundary near 1,000 sockets.
The default cleanup path deletes each connection through `EngineClient.delete_connection` before
deleting its synthetic user, ensuring Wirekeeper closes the corresponding upstream socket. An
interrupted run can be rerun only after its lifecycle cleanup succeeds or the disposable pseudo-VPS
is reset.

If the process is killed before its default cleanup completes, take the run ID from the partial JSON
filename and clean it explicitly before another run:

```sh
bin/apptools testvps load-cleanup --run_id=20260901t120000z
```

Cleanup failure deliberately leaves both the synthetic IRC sidecar and the no-swap runtime limit in
place so retained sockets are not silently cut off. Fix the reported lifecycle failure and rerun
`load-cleanup`; only successful cleanup removes the sidecar and restores the build-swap allowance.

The runner does not add a network-accessible load-test endpoint to the production gateway. It uses
the gateway release's local RPC command as a tightly scoped bootstrap channel, creates at most 100
users/connections per batch, limits concurrent engine requests, pins every connection server-side
in the harness to `topics-club-vps-irc:6667` without TLS, and uses the normal `EngineClient`
connection and deletion lifecycle. The RPC command requires local destination access and the
release cookie, while an HTTP endpoint would unnecessarily expose synthetic account creation in the
production artifact.

Each run writes an incrementally updated
`.load-tests/<run-id>-testvps-load.json` file. The result records the local harness revision and each
deployed gateway, Wirekeeper, and engine release's tag and commit from its deployment manifest.
Samples contain:

- the outer app-host cgroup's reset-at-baseline memory peak, no-swap limit, OOM events, and current
  use;
- Docker usage for the app host plus the external PostgreSQL and IRC sidecars;
- per-service systemd memory, CPU, task, PID, and restart counters;
- gateway, engine, and Wirekeeper BEAM memory/process/port/run-queue diagnostics;
- exact database, engine Session, Wirekeeper open/attached/detached/buffer/drop, and IRC socket
  counts; and
- local `/health` response status and latency.

At every requested checkpoint the runner provisions only the delta, waits for all count invariants,
holds them steady, stops and restarts the engine while Wirekeeper retains the sockets, injects one
record per detached socket, and requires reattachment without increasing the IRC server's accepted
socket count. At the final checkpoint it also sends one uniquely keyed command per connection from
the gateway through the engine and requires the synthetic IRC server to receive exactly that many
`PRIVMSG` commands. It then sends a distinct `NOTICE` marker to every IRC socket and requires an
exact marker count in Postgres. Finally, it drops all upstream sockets and requires exactly one
fresh accept per configured connection. The external IRC sidecar gets 768 MiB, one CPU, and 65,536
file descriptors; its metrics are recorded so its saturation cannot be mistaken for TopicsClub
capacity.

The pseudo-VPS starts with 2 GiB RAM plus a 4 GiB build-only swap allowance. The runner changes the
outer container to a 2 GiB no-swap runtime limit, resets the cgroup memory peak so release builds do
not contaminate the measurement, and restores the build allowance after cleanup. That 2 GiB
aggregate includes Ubuntu/systemd, the destination-side Docker daemon and cache, and all three BEAM
releases. The separately capped 384 MiB PostgreSQL and 768 MiB synthetic IRC containers are
excluded. This is therefore an application-host capacity result with an external database, not an
all-in-one 2 GiB host result.

For planning, use the highest fresh-run checkpoint that passes traffic and both recovery phases,
uses no swap, reports no OOM/restart/drop/IRC-send/provisioning or RPC timeout errors, keeps all
services and the end-to-end health endpoint healthy, and remains at or below 80% of the app-host
cgroup peak. A higher functional checkpoint is a stress result, not the operating ceiling. After
finding the boundary, repeat the proposed ceiling from a reset pseudo-VPS with a one-hour
`--steady_seconds=3600` hold.

## Current split-release result

Run `20260901t074527z` completed on 2026-09-01 with harness revision
`82dcf6326922f7f71f180f938d85141f9c09578a`. Gateway and engine used tag `20260901.3` at commit
`40a35c3f4d85d7417fb244b38d8001e7435a18a1`; the intentionally long-lived Wirekeeper process
remained on tag `20260901.2` at commit `4c2da3b81fba8dbe49b12fb96ed5034dcb878199`.

All checkpoints passed the functional and planning predicates. Each engine restart retained the
existing Wirekeeper sockets: the IRC accepted count before and after resume was exactly the listed
connection count. No service restarted unexpectedly, no cgroup OOM or swap use occurred, the IRC
sidecar reported no send errors, and Wirekeeper reported no dropped records or bytes.

| Connections | Provision | Ready | Peak app-host bytes | Peak of 2 GiB | Resume accepts |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 100 | 1.212 s | 6.837 s | 550,674,432 | 25.64% | 100 → 100 |
| 500 | 4.799 s | 6.946 s | 636,071,936 | 29.62% | 500 → 500 |
| 1,000 | 6.092 s | 6.838 s | 714,584,064 | 33.28% | 1,000 → 1,000 |
| 2,000 | 12.373 s | 7.086 s | 943,587,328 | 43.94% | 2,000 → 2,000 |
| 3,000 | 12.425 s | 6.888 s | 1,131,356,160 | 52.68% | 3,000 → 3,000 |
| 4,000 | 11.570 s | 6.923 s | 1,644,011,520 | 76.56% | 4,000 → 4,000 |

The 4,000-session peak includes the final forced reconnect phase. At that checkpoint:

- all 4,000 gateway-to-engine commands returned `sent`, the IRC sidecar received exactly 4,000
  `PRIVMSG` commands, and exactly 4,000 corresponding message rows existed after server echo;
- the IRC sidecar sent 4,000 inbound `NOTICE` markers with zero errors and Postgres contained
  exactly 4,000 rows for that distinct marker;
- force-closing 4,000 upstream sockets changed total IRC accepts from 4,000 to exactly 8,000 and
  restored all configured sessions; and
- lifecycle cleanup deleted all 4,000 connections through the engine before deleting their users,
  leaving zero test connections and users.

This establishes **4,000 as the current 2 GiB planning checkpoint**, not a measured maximum. The
hold was 30 seconds per checkpoint, not the recommended one-hour soak. PostgreSQL and the synthetic
IRC server were separately capped and excluded from the 2 GiB app-host limit; IRC was plaintext and
synthetic, so the result does not price TLS, public-network latency, channel fan-out, normal user
history, or a production database workload. One transient gateway RPC sampling error was recorded
during an intentional engine stop and recovered within the polling window; service restart counters
remained zero and the phase invariants subsequently passed.

The raw incremental artifact remains local at
`.load-tests/20260901t074527z-testvps-load.json`. This section is the committed durable conclusion;
the exact command and resource boundaries are documented above so the result can be reproduced.

After the applied-revision fence was made immutable in `5da3cc8`, run `20260901t081907z` repeated
the complete scenario at 100 sessions with engine tag `20260901.4`, gateway `.3`, and Wirekeeper
`.2`. It retained the same 100 accepts across engine restart, delivered and persisted exactly 100
markers in each direction, moved from 100 to exactly 200 accepts after deliberate socket loss, and
cleaned up to zero users and connections. This focused post-fix run is regression evidence for the
final engine artifact; it does not replace the 4,000-session capacity measurement above.

## Historical direct-transport results

### Standalone engine: idle sockets

All levels through 15,000 completed registration and the steady hold. No failure boundary was
tested beyond 15,000, so the result is **at least 15,000 idle sessions**, not an assertion that
15,001 fails or that 15,000 is safe for production.

| Connections | Startup | Engine memory after hold | Cgroup use | BEAM processes | Ports |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 100 | 7.54 s | 144.9 MiB | 9.4% | 386 | 116 |
| 500 | 7.74 s | 203.0 MiB | 13.2% | 1,186 | 516 |
| 1,000 | 10.57 s | 283.5 MiB | 18.5% | 2,186 | 1,016 |
| 2,000 | 18.38 s | 426.6 MiB | 27.8% | 4,185 | 2,016 |
| 4,000 | 29.08 s | 733.5 MiB | 47.8% | 8,185 | 4,016 |
| 6,000 | 50.52 s | 1.031 GiB | 68.7% | 12,185 | 6,016 |
| 8,000 | 61.73 s | 1.367 GiB | 91.1% | 16,185 | 8,016 |
| 10,000 | 72.23 s | 1.455 GiB | 97.0% | 20,185 | 10,016 |
| 15,000 | 114.30 s | 1.500 GiB | 99.98% | 30,185 | 15,016 |

The near-limit 10,000 and 15,000 results are useful as a lab maximum only. They have almost no
memory reserve for channel state, message bursts, TLS, allocator variation, or operating-system
differences.

### Standalone engine: data and recovery

The paced workload passed at 8,000 sessions:

- 8,000 app-to-server messages completed in 10.00 seconds, and the local server echoed them.
- 8,000 server-to-app messages were persisted in 9.27 seconds.
- Restarting the engine restored all sockets in 51.85 seconds.
- Engine memory after traffic was 1.457 GiB of 1.5 GiB (97.1%).

That proves the data path at 8,000, but the memory level makes it an unsafe production target for
this container size.

The final 4,000-session scenario, after the fixes below, passed every phase:

| Phase | Result |
| --- | ---: |
| Initial connection restoration | 30.50 s |
| 4,000 outbound messages | 5.45 s |
| 4,000-message inbound spike sent by server | 233 ms |
| All 4,000 marker-specific inbound messages persisted | 4.13 s |
| Engine restart restoration | 30.25 s |
| Forced socket-loss recovery | 6.93 s |
| Engine memory after traffic | 871.8 MiB / 1.5 GiB (56.8%) |

This is the strongest tested operating point: it includes substantial memory headroom, both data
directions, persistence, restart, and transport recovery.

### Combined release and HTTP

Each scenario kept all IRC sessions connected during a 10-second hold, then sent 200 requests at
concurrency 20 to each endpoint. The authenticated benchmark user owned one of the IRC
connections; the remaining users supplied background engine load.

| IRC sessions | Startup | App memory | `/health` req/s | health p95 | `/api/bootstrap` req/s | bootstrap p95 | Errors |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1,000 | 11.12 s | 325.2 MiB (21.2%) | 1,325.5 | 19.31 ms | 536.9 | 69.92 ms | 0 |
| 4,000 | 32.29 s | 759.9 MiB (49.5%) | 1,429.6 | 21.61 ms | 550.7 | 79.62 ms | 0 |
| 8,000 | 63.53 s | 1.396 GiB (93.0%) | 1,530.7 | 14.71 ms | 621.0 | 56.58 ms | 0 |
| 10,000 | 73.48 s | 1.454 GiB (97.0%) | 1,385.2 | 17.17 ms | 507.1 | 77.01 ms | 0 |

The HTTP sample is intentionally small and local; its purpose is to detect collapse or large
latency regression while IRC sessions are resident. It is not an internet-facing throughput SLA,
and it does not cover thousands of simultaneous Phoenix channels or browser WebSockets. Success
also required every IRC session to remain registered and every synthetic-server socket to remain
active after the HTTP phase.

## Bottlenecks and changes

### 1. Memory is the hard connection ceiling

The engine uses roughly two BEAM processes and one socket port per IRC connection, plus connection
state, parsed protocol data, and persisted-event binaries. Docker working-set memory rose from
about 284 MiB at 1,000 sessions to 1.367 GiB at 8,000. CPU fell back near idle after registration;
memory, not steady-state CPU, is the practical socket ceiling.

Recommendation for the tested 1.5 GiB / 2 CPU container: use **4,000 connections as the planning
ceiling** until a longer and more realistic soak proves otherwise. Eight thousand passed active
traffic but left only about 3% memory in the standalone workload. Ten thousand combined and
15,000 idle standalone are stress results, not capacity promises.

### 2. Cold restoration is CPU and database bound

At 500 sessions and above, startup samples reached roughly 150–160% engine CPU and about 100%
Postgres CPU. Startup then grew almost linearly with connection count. Increasing bouncer
concurrency would add coordination while both allocated compute resources are already saturated,
so it was not implemented.

The simple levers are more engine CPU, more Postgres CPU, and measuring again. Increasing only the
Ecto pool is unlikely to help while the one-CPU Postgres container is already saturated.

### 3. Short DB checkout queues dropped synchronized inbound messages

Before tuning, a 4,000-message spike sent in 117 ms persisted only 3,482 messages even after three
minutes. At 8,000, 4,384 were persisted. IRC message routing rescues
`DBConnection.ConnectionError`, so an exhausted checkout queue becomes message loss.

Production runtime configuration now defaults `DB_QUEUE_TARGET` and `DB_QUEUE_INTERVAL` to 5,000
ms and leaves both configurable. With that backpressure, a 4,000-message spike sent in 233 ms
persisted all 4,000 in 4.13 seconds. Normal paced traffic is unaffected.

This is not durable queuing. If Postgres is unavailable longer than the checkout window, inbound
messages may still be lost. A disk-backed ingress queue would be a separate architectural project
and should not be added unless the product requires that guarantee.

### 4. Transport loss did not reconnect

`Ircxd.Client` defaults reconnection off, and the application had not enabled it. Forced socket
loss therefore left session processes present but disconnected. Client options now retry forever
at a fixed five-second interval. The final 4,000-session run restored every socket in 6.93 seconds
with exactly 4,000 new accepts.

## Lab notes

- The first shakedown incorrectly used the stored `server_connections.status` as its success
  signal. Runtime status is intentionally broadcast rather than persisted, so success now uses the
  engine registry and the synthetic server's active/registered counts.
- Capacity registration itself is two-way traffic: the client sends IRC capability and identity
  commands, and the server sends welcome, feature, and MOTD replies that the app parses and
  persists.
- A 15-second steady hold caught no spontaneous disconnects in the capacity sweep.
- Instantaneous and paced traffic are kept distinct. A burst failure must not be hidden behind a
  slower average-throughput number.
- A reconnect-jitter experiment at 4,000 sessions did not improve recovery and was removed. The
  fixed-delay implementation is simpler and performed better after DB queue backpressure was
  added.
- The engine release image sets a UTF-8 locale so release RPC diagnostics do not emit native-name
  encoding warnings.

## What remains before using this as a production SLA

- Run multi-hour and multi-day soaks at the proposed ceiling.
- Add realistic joined-channel membership and user-list cardinalities.
- Repeat with TLS IRC connections and representative IRC network latency.
- Load Phoenix WebSockets and fan-out events, not only HTTP endpoints.
- Test Postgres interruption and decide explicitly whether durable inbound queuing is required.
- Repeat on the actual production CPU, kernel, memory limit, and Postgres service.
- Alert on container memory, connection restoration duration, DB checkout failures, and reconnect
  churn; treat 80% sustained memory as an early warning rather than waiting for OOM.
