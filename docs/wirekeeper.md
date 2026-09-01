# Wirekeeper

Wirekeeper is the `:topics_club_wirekeeper` OTP application under
`apps/topics_club_wirekeeper`. It owns long-lived upstream TCP/TLS connections independently from
the processes that consume their traffic. This lets an engine consumer disappear and reattach
without making consumer loss mean socket loss.

Wirekeeper currently lives inside the TopicsClub umbrella. It has its own application callback,
supervision tree, public API, tests, and no runtime dependencies on the other umbrella applications.
It has not yet been extracted into the separate `wirekeeper` repository. The engine compiles
against it only in tests; production uses a distributed call boundary, so the standalone engine
release does not contain or start Wirekeeper.

TopicsClub now has a fourth release, `topics_club_wirekeeper`, containing only this OTP application
and its OTP/runtime dependencies. In the supported split deployment it runs as a third systemd
service in front of the engine. The combined release and ordinary Mix runtime continue to use
Ircxd's direct socket transport by default.

## Relationship to the original concept

The implementation keeps the central premise described by the standalone Wirekeeper project:
socket ownership is independent from consumer ownership, connections have opaque identities and
generations, and application protocol policy stays outside the transport core.

The OTP application in this umbrella makes these concrete choices today:

| Concern | Current implementation |
| --- | --- |
| Upstream leg | Raw binary TCP or TLS owned by a Wirekeeper connection process; UDP is not implemented. |
| Consumer leg | One local or remote Erlang PID; a TCP or WebSocket consumer adapter is not implemented. |
| Detached traffic | Bounded, sequence-numbered records are retained for replay instead of being drained and discarded. |
| Delivery | Bounded at-least-once delivery with cumulative ACKs, not exactly-once delivery. |
| Protocol awareness | The core executes a per-connection protocol adapter. The included IRC adapter frames lines and owns PING/PONG; the core itself remains protocol-neutral. |
| Engine boundary | An opt-in Ircxd client transport adapter attaches the engine Session PID, replays retained IRC lines, and checkpoints Ircxd parser state. |
| Deployment | A standalone Wirekeeper BEAM node can outlive an engine release restart; combined mode remains direct. |

The protocol-adapter boundary is a notable extension to the original transport-only premise. It
allows maintenance traffic that must survive the consumer to execute beside the socket without
putting general IRC session behavior into Wirekeeper.

## Runtime architecture

The `:topics_club_wirekeeper` application callback starts this `:rest_for_one` tree:

```text
TopicsClub.Wirekeeper.Supervisor
├── ConnectionRegistryOwner
│   └── unique TopicsClub.Wirekeeper.ConnectionRegistry
├── ConnectionSupervisor (DynamicSupervisor)
│   └── one temporary Connection process per open or retained connection
├── OpenTaskSupervisor (at most 8 children)
└── Manager
```

The manager serializes key reservations but performs adapter initialization and network connection
work in supervised tasks. A slow TCP connect or TLS handshake therefore does not block lookup or
other connection routing. At most eight opens may be pending; another open is rejected with
`{:error, :overloaded}`. If an opening caller exits, its task and any connection created for that
opening are cleaned up. An optional application-wide `:max_connections` limit counts reserved
openings and open sockets, but not closed tombstones. Once that limit is reached, another open is
rejected with `{:error, :connection_limit}`. The default is unlimited; production should set a
positive limit from measured host capacity rather than relying on an invented universal value.

The unique Registry maps a connection key to its connection process and its `:opening`, `:open`, or
`:closed` generation state. Calls do not need to query a potentially busy socket owner merely to
find it.

Each connection GenServer exclusively owns:

- one TCP or TLS socket;
- one opaque integer or non-empty binary key;
- one random 128-bit generation encoded as lowercase hexadecimal;
- adapter module and adapter state;
- an anonymous private ETS `ordered_set` of sequence-numbered binary records;
- delivery credit, cumulative ACK state, and overflow counters;
- up to 4,096 successful generation-local outbound idempotency keys by default;
- one bounded plain-data consumer checkpoint retained without interpretation; and
- at most one attached local or remote consumer PID.

A connection child is temporary. Wirekeeper never automatically reconnects an upstream connection.
Restarting only the manager leaves established connection processes, sockets, and ETS buffers
intact. Losing the registry owner restarts the later children in the `:rest_for_one` tree, which
closes connections because Wirekeeper can no longer safely enforce unique connection identity.

## Identity and consumer ownership

Opening a key that is opening, open, or retained as a closed tombstone returns
`{:error, :already_open}`; it never replaces the existing socket implicitly. Every attach, detach,
ACK, send, send-once, and close operation must include the generation returned by `open/3`. A stale
consumer therefore cannot operate on a replacement socket that reused the same key.

Only one consumer PID can be attached to a generation. One small local watcher monitors the
consumer, including when it is a PID on a connected Erlang node. Consumer or node loss starts a
detached episode without closing the upstream socket. An explicit generation-matched detach has the
same effect.

Delivery uses `:erlang.send/3` with `:nosuspend` and `:noconnect`. Wirekeeper does not block a socket
owner or establish a distribution connection to deliver an event. If the consumer cannot accept a
data, overflow, or close event immediately, Wirekeeper detaches it and retains bounded state for a
later attachment. If this happens during `attach/3`, that call returns
`{:error, :consumer_unreachable}` instead of reporting a successful attachment.

Wirekeeper does not authenticate or authorize a remote PID. Any future cross-node boundary must add
that policy outside or in front of the current API.

The attached consumer may store a checkpoint with `put_checkpoint/4`. A checkpoint is a plain map
containing only nested maps, lists, atoms, numbers, booleans, and binaries; structs, tuples, PIDs,
references, ports, and functions are rejected. The default encoded-size limit is 65,536 bytes, and
Wirekeeper retains a serialized copy so a small sub-binary cannot keep a much larger source binary
alive. The checkpoint is generation-scoped, can only be replaced on behalf of the currently attached
PID, and is returned in later attachment summaries. Wirekeeper neither interprets it nor exposes it
through `info/1`, `list/0`, or `diagnostics/0`. Shape validation cannot identify secrets: callers
must never include credentials, tokens, or other sensitive values.

A resumable consumer instead uses `ack_with_checkpoint/5` to encode the post-record checkpoint and
cumulatively ACK its matching sequence in one connection-process state transition. Validation
failure changes neither value. The first successful combined call puts that generation into
checkpointed-ACK mode: later new ACKs must also carry checkpoints, and separate checkpoint writes
are rejected. Idempotent retries cannot replace a checkpoint associated with a newer sequence.

## Buffering, replay, and ACKs

Every `{:forward, payload}` action from the adapter becomes one complete record. The connection
assigns a monotonically increasing sequence scoped to the generation, copies the payload into its
private ETS table, and then attempts bounded delivery.

The defaults per connection are:

| Option | Default | Meaning |
| --- | ---: | --- |
| `:max_records` | 1,000 | Maximum retained records |
| `:max_bytes` | 1,048,576 | Maximum retained payload bytes |
| `:max_in_flight` | 64 | Maximum delivered but unacknowledged records |

These values are set under the `:buffer` option to `open/3`. All three must be positive integers.
The buffer is memory-only because losing its owning connection process also loses the socket whose
session the records describe; disk or database persistence would not preserve that TCP session.

Delivery is bounded at-least-once:

- Records remain retained until the attached consumer cumulatively acknowledges a delivered
  sequence with `ack/4`.
- An ACK deletes that sequence and every retained earlier sequence. ACKs at or below the current
  watermark are idempotent for the attached consumer.
- If the consumer exits or detaches first, in-flight credit is reset and the next consumer receives
  the retained unacknowledged records again. Consumers must tolerate duplicates.
- No more than `:max_in_flight` records are placed in a consumer mailbox without ACKs. ACKing a
  delivered sequence releases credit and dispatches later retained records in order.

When a record or byte bound is exceeded, Wirekeeper evicts the oldest retained complete records. A
single record larger than `:max_bytes` is dropped without evicting the records already retained.
Dropped record and byte counters are cumulative for the generation and are not reset by attachment.
An attachment summary sets `gap?: true` after any drop and reports the exact totals, replay size,
and detached duration.

An evicted record that was already delivered still occupies in-flight credit until it is ACKed or
the consumer detaches. This prevents a non-acking consumer from turning steady overflow into an
unbounded mailbox. Live overflow events are coalesced to one outstanding notification per ACK or
attachment boundary; `info/1` and every later attachment summary continue to expose the cumulative
totals.

The consumer receives plain messages:

```elixir
{:topics_club_wirekeeper,
 {:data, %{key: key, generation: generation, sequence: sequence, payload: bytes}}}

{:topics_club_wirekeeper,
 {:overflow,
  %{
    key: key,
    generation: generation,
    dropped_records: records,
    dropped_bytes: bytes,
    total_dropped_records: total_records,
    total_dropped_bytes: total_bytes
  }}}

{:topics_club_wirekeeper,
 {:upstream_closed, %{key: key, generation: generation, reason: reason}}}
```

## Upstream closure and tombstones

An explicit `close/2` closes the socket and terminates the connection immediately. A peer close,
transport error, send failure, or protocol-adapter error instead transitions the connection to
`:closed` and records the reason.

If records remain unacknowledged, no consumer is attached, or a close event cannot be delivered,
the closed connection remains registered as a tombstone for `:closed_retention_ms`, which defaults
to 60 seconds. A consumer may attach during that period. Wirekeeper delivers retained records in
sequence before the `:upstream_closed` event. The tombstone terminates after the last retained record
is ACKed or when its retention timer expires. Wirekeeper does not reopen it.

## Protocol adapters

`TopicsClub.Wirekeeper.ProtocolAdapter` is initialized once for each connection and consumes raw
inbound socket chunks in the socket-owning process. It returns ordered actions:

```elixir
{:forward, binary_record}
{:reply, iodata}
```

A forward action is copied into the replay buffer before delivery. A reply action is written
directly to the upstream socket whether or not a consumer is attached and is never added to the
buffer. Adapter actions are applied in order. Invalid callback results or actions close only the
affected connection with a protocol or transport error.

Adapters run inside the connection process, so they must not block and must not attempt to own the
socket themselves.

### Passthrough

`TopicsClub.Wirekeeper.ProtocolAdapter.Passthrough` is the default. It emits every inbound transport
chunk unchanged as one retained record. TCP chunk boundaries are not application message
boundaries, so a protocol that needs framing must select another adapter.

### IRC keepalive

`TopicsClub.Wirekeeper.ProtocolAdapter.IrcKeepalive` is the implemented IRC adapter. It:

- reconstructs complete IRC records from fragmented TCP/TLS chunks and preserves non-PING records
  byte-for-byte;
- treats each line ending in `\n` as one record, including both CRLF and LF input;
- skips optional leading IRCv3 tag and prefix sections before matching the `PING` command
  case-insensitively;
- replies once with `PONG` and the received PING parameters directly from the connection process;
- does not forward or buffer a handled PING, so an engine cannot send a duplicate PONG and PING
  traffic cannot contribute to replay overflow; and
- bounds a complete or partial line with `:max_line_bytes`, defaulting to 16,384 bytes.

If a line exceeds the bound, actions for earlier complete lines in the same chunk are applied first,
then the affected connection closes with `{:protocol_error, :line_too_long}`. General IRC behavior
such as registration, capabilities, SASL, nicknames, joins, messages, persistence, and reconnect
policy does not belong in this adapter.

## Public API

The public entry point is `TopicsClub.Wirekeeper`:

| Function | Current behavior |
| --- | --- |
| `open/3` | Reserves a key, connects TCP/TLS, starts detached, and returns its generation and initial info. |
| `attach/3` | Attaches one PID and returns a replay/overflow summary while dispatching retained records. |
| `detach/3` | Detaches only the matching PID without closing upstream. |
| `ack/4` | Cumulatively acknowledges a sequence delivered to the matching PID. |
| `ack_with_checkpoint/5` | Atomically retains post-record consumer state and cumulatively acknowledges its matching sequence. |
| `put_checkpoint/4` | Replaces the bounded checkpoint for the generation's matching attached PID. |
| `send_data/3` | Sends iodata upstream through the generation-matched open socket. |
| `send_data_once/4` | Sends one record for a nonempty set of generation-local idempotency keys, or suppresses it when all keys were already written. Partial overlap fails closed. |
| `close/2` | Explicitly closes and removes the generation-matched connection. |
| `info/1` | Returns one connection's status and bounded counters, but no payloads or credentials. |
| `list/0` | Returns sorted info for current open connections and retained tombstones; openings are omitted. |
| `diagnostics/0` | Reports transport API version 1, the additive `:send_once` feature, and aggregate connection/buffer counters. |

Typical IRC-oriented use is:

```elixir
alias TopicsClub.Wirekeeper
alias TopicsClub.Wirekeeper.ProtocolAdapter.IrcKeepalive

{:ok, opened} =
  Wirekeeper.open(
    connection_id,
    {:tls, host: "irc.example.net", port: 6697},
    protocol_adapter: {IrcKeepalive, []},
    buffer: [max_records: 1_000, max_bytes: 1_048_576, max_in_flight: 64]
  )

{:ok, replay} = Wirekeeper.attach(connection_id, opened.generation, self())

receive do
  {:topics_club_wirekeeper, {:data, %{sequence: sequence, payload: line}}} ->
    process_irc_line(line)
    :ok = Wirekeeper.ack(connection_id, opened.generation, sequence)
end

:ok = Wirekeeper.send_data(connection_id, opened.generation, "NICK example\r\n")

:ok =
  Wirekeeper.send_data_once(
    connection_id,
    opened.generation,
    [join_attempt_id],
    "JOIN #elixir\r\n"
  )
```

`attach/3`, `detach/3`, and `ack/4` default their consumer argument to the calling process. Repeating
`attach/3` from the already attached PID is idempotent and does not replay records a second time.

Outbound send-once keys are nonempty binaries up to 128 bytes, and at most 64 keys may guard one
write. A connection refuses a new key after its configured bound. A retry is suppressed only when
every key is already present; partial overlap returns `:idempotency_conflict`, preventing a
multi-key write from being partially assumed written. TopicsClub currently disables multi-target
JOIN until per-target outcomes are implemented. Keys reset with a fresh generation.

The `open/3` connection options are:

| Location | Option | Default |
| --- | --- | --- |
| Transport | `:host` | required non-empty string |
| Transport | `:port` | required integer from 1 through 65,535 |
| Transport | `:connect_timeout` | 10,000 ms |
| Transport | `:send_timeout` | 5,000 ms |
| TLS transport | `:tls_options` | peer verification using the host trust store and HTTPS-style hostname checking |
| Open options | `:protocol_adapter` | `{TopicsClub.Wirekeeper.ProtocolAdapter.Passthrough, []}` |
| Open options | `:buffer` | the buffer defaults documented above |
| Open options | `:checkpoint_max_bytes` | 65,536 bytes |
| Open options | `:sent_once_max_keys` | 4,096 keys |
| Open options | `:closed_retention_ms` | 60,000 ms |

The optional application setting `config :topics_club_wirekeeper, max_connections: positive_integer`
limits all opening and open generations across keys. It is separate from per-connection `open/3`
options and is unlimited when absent. In the standalone release,
`TOPICS_CLUB_WIREKEEPER_MAX_CONNECTIONS` supplies this value and rejects zero, negative, or malformed
values during boot.

TCP and TLS use raw binary sockets with active-once reads and finite sends. TCP also enables
`nodelay` and transport keepalive. TLS verifies DNS hostnames and IP subject alternative names by
default; IP literals are connected as addresses rather than sent as IP-valued SNI. Caller-supplied
`:tls_options` may override TLS policy, but Wirekeeper always enforces raw binary mode, passive
setup, and the top-level finite `:send_timeout`.

Public calls convert manager or connection call exits to `{:error, :unavailable}`. This keeps a
temporarily unavailable supervision component distinct from `{:error, :not_found}` and
`{:error, :opening}`.

## Engine and Ircxd integration

`TopicsClub.Irc.WirekeeperTransport` implements the optional `Ircxd.Client.Transport` contract.
The Ircxd change is described in `docs/ircxd-wirekeeper-transport.md`; callers that do not select a
custom adapter still use Ircxd's built-in `Ircxd.Client.Transport.Socket` adapter and retain the
existing `:gen_tcp`/`:ssl` behavior.

The stable Wirekeeper key is `server_connections.id`. The attached consumer is the engine
`TopicsClub.Irc.Session` PID, not the short-lived Ircxd client PID. That distinction lets an abrupt
Ircxd client exit detach and replay through the same Session during retry, while loss of the engine
node also detaches its remote Session PID without closing upstream.

The Ircxd resume binding is `server-connection/<id>/transport-revision/<revision>`, optionally
extended by a deployment binding. The database revision increments when effective socket or IRC
identity settings change, including host, port, TLS, nickname, and SASL credentials. Ircxd also
binds the selected opt-in vendor-numeric policy. A mismatch rejects the old checkpoint and closes
that retained generation before making a fresh connection, so a settings edit cannot accidentally
resume an incompatible IRC session. Adding the first SASL password without an explicit SASL
username derives the username from the effective nickname.

For a fresh connection the adapter:

1. Opens TCP or TLS in Wirekeeper with `IrcKeepalive` and the configured replay-buffer limits.
2. Attaches the Session PID.
3. Returns `:fresh` to Ircxd, which sends its normal PASS/CAP/SASL/NICK/USER registration writes
   through `Wirekeeper.send_data/3`.

For an existing generation it first clears any stale attachment for the same Session PID, attaches,
and inspects the replay summary. A generation is
resumed only when no records were dropped and a valid Ircxd checkpoint exists. A gap or missing
checkpoint makes the adapter detach, explicitly close that generation, wait for its key to be
released, and open one fresh IRC connection. If a fresh open succeeds but attachment fails, the
adapter best-effort closes that exact generation instead of leaking a detached socket.

On resume Ircxd restores its bounded, versioned parser checkpoint, emits connected/resumed/
registered events, and does not repeat PASS, CAP, SASL, NICK, or USER. The checkpoint includes the
state Ircxd mutates while accepting inbound records: nickname, capability and ISUPPORT state,
message-ID deduplication, and bounded parser/batch accumulators. Its binding fingerprints connection
and authentication policy without retaining credential values. Fresh credential-bearing IRC writes
do pass through `send_data/2`; credentials are excluded from retained records, checkpoints,
diagnostics, and logs.

JOIN is the one outbound operation with durable retry identity. The `channel_memberships` row has a
nullable `join_attempt_id` UUID. Creating a membership or retrying one in `left`/`error` state
assigns a new UUID in the same locked transaction that makes it pending; an already-pending attempt
preserves its UUID, and a legacy pending row is backfilled before transmission. On a fresh IRC
generation, confirmed auto-joins are transactionally moved to pending with new UUIDs before the
registration record is acknowledged. The supported single-target managed JOIN persists its
membership before passing the attempt UUID with the wire record. The transport primitive accepts
an atomic key set, although TopicsClub's current managed-command policy accepts only one JOIN target.

`WirekeeperTransport.send_data_once/3` calls `Wirekeeper.send_data_once/4`. The socket owner records
the keys only after the socket send returns `:ok`. If the engine disappears after that reply,
Wirekeeper still remembers the keys; if it disappears before the call, the keys are absent. An
uncertain distributed-call result is never followed by an ordinary write. The membership remains
pending so the same keys are retried.

Every complete Wirekeeper IRC record is delivered to Ircxd with its sequence as an opaque receipt.
Ircxd parses the record and sends all resulting events to the Session before it calls the adapter's
`accepted/3` callback. Because those messages come from the same Ircxd process, the Session handles
the events before the acceptance marker. It then calls `ack_with_checkpoint/5`, atomically storing
the post-record checkpoint and cumulatively ACKing the sequence. Before registration produces a
checkpoint, it uses the plain ACK path. If Ircxd reports that no safe checkpoint can be made, or the
atomic ACK fails, the adapter closes the generation rather than advancing replay without resumable
state.

Persistence failure is handled differently from an unsafe checkpoint. The Session records failures
while dispatching all events produced by a delivered record. At its acceptance marker it detaches
the consumer, reports the Ircxd transport closed, and deliberately leaves both the record and socket
unacknowledged. Retry reattaches to the same retained generation and replays the record. Persisted
message, system-line, direct-message, and channel/server-line effects claim a unique
`{connection_id, generation, sequence, effect_key}` row in the same database transaction, making a
replayed effect idempotent. Claims through a cumulatively acknowledged sequence are released later
in bounded batches; deleting the connection cascades any remaining claims. Because the remote ACK
and database cleanup cannot share one transaction, the engine also performs bounded cold-start and
periodic reconciliation. It pages distinct claim generations, asks Wirekeeper for the authoritative
cumulative ACK watermark, deletes claims through that watermark, and deletes a generation's claims
when that generation no longer exists. An unavailable Wirekeeper boundary leaves claims intact for
the next pass. This closes an engine-crash window after a successful ACK but before the volatile
cleanup cast. The transport contract is still at-least-once, while these persisted effects are
applied once. JOIN rejection and command status updates are also replay-safe: unchanged writes do
not rebroadcast, and the Session keeps the pending command and membership in memory when either
durable update fails.

Wirekeeper overflow is not reconciled on the retained socket. The engine closes the gapped
generation, tells Ircxd that the transport failed, and establishes one fresh IRC connection. An
upstream close is likewise surfaced through Ircxd's normal disconnect/retry path. Late records from
a detached client are left unacknowledged and replayed after attachment; stale Ircxd transport
handles cannot inject them into a replacement client.

The Session persists inbound events before the acceptance marker is handled. On a valid resume it
restores `joined` auto-join memberships into its in-memory joined set. Persisted `pending`
memberships are restored as pending but not assumed sent. The resumed registered event flushes each
one with its durable UUID: Wirekeeper performs a missed write or suppresses an already-written one.
The Session sends NAMES once for every persisted joined membership to rebuild presence without
rejoining the channel.

Shutdown intent is explicit:

- an engine/Session or Ircxd crash detaches the consumer and retains the socket;
- loss or replacement of the Wirekeeper node is observed by each Ircxd client and enters its normal
  disconnect/reconnect path instead of leaving a stale generation handle connected;
- an ordinary user QUIT, authoritative user reconnect, connection deletion, and active transport
  settings edit close the generation. A reconnect or edit then opens exactly one fresh generation;
- the inactive-session sweep closes a detached generation for an inactive connection that the
  engine intentionally does not restore;
- a replay gap, unavailable checkpoint, rejected connection, or failed acceptance also closes the
  affected generation so retry is fresh.

An unavailable Wirekeeper node is different from an upstream IRC failure. The engine keeps retrying
the Wirekeeper boundary indefinitely, because asking a user to repair an internal service outage
would strand a socket Wirekeeper may still own. Ordinary upstream disconnects retain the normal
bounded reconnect-and-help policy. A persistence-triggered replay is likewise an internal retry:
it preserves pending commands, does not emit a false user-visible disconnect, and is not capped by
the ordinary five-attempt upstream policy.

The integration suite runs the same real Session connect/join/send/persist and JOIN-rejection
scenarios in both direct and Wirekeeper modes. Wirekeeper-specific cases cover engine Session
replacement, pending JOIN recovery that sends a missed attempt and suppresses an already-written
attempt, an abrupt Ircxd client crash,
replay after a persistence failure, idempotent persistence, absence of duplicate registration
writes, authoritative reconnect and settings changes, inactive-orphan cleanup, and permanent
deletion cleanup. The production-like split acceptance check also replaces Wirekeeper while the
engine stays up and proves that the engine establishes and persists traffic from a fresh IRC
connection rather than retaining the stale generation handle.

## Release and deployment

The production split consists of three co-located BEAM services plus PostgreSQL:

```text
browser -> topics_club_gateway -> topics_club_engine -> topics_club_wirekeeper -> IRC server
                    |                    |
                    +------ PostgreSQL --+
```

The nodes use the same distribution cookie and loopback-only distribution:

| Release | Default node | Fixed distribution port | Database access |
| --- | --- | ---: | --- |
| `topics_club_gateway` | `topics_club_gateway@localhost` | 4370 | yes |
| `topics_club_engine` | `topics_club_engine@localhost` | 4371 | yes |
| `topics_club_wirekeeper` | `topics_club_wirekeeper@localhost` | 4372 | no |

The split engine defaults `TOPICS_CLUB_IRC_TRANSPORT` to `wirekeeper` and defaults
`TOPICS_CLUB_WIREKEEPER_NODE` to `topics_club_wirekeeper@localhost`. Setting the transport to
`direct` explicitly keeps Ircxd on its built-in socket adapter. Mix and the combined release remain
direct without configuration.

On an empty host, deploy Wirekeeper once before the first gateway-and-engine deployment. Thereafter,
`bin/apptools deploy` activates gateway and then engine while deliberately leaving Wirekeeper alone.
Each component can still be selected explicitly. Deploying only the engine, or using the default
two-role deployment, leaves the Wirekeeper OS process, sockets, buffers, and checkpoints intact.
Deploying or rolling back Wirekeeper necessarily replaces its node and therefore its sockets.

Compatibility is contractual rather than tied to one repository tag. `diagnostics/0` publishes
transport API version 1 plus additive feature names. The Wirekeeper health unit requires that
version locally, and the engine health unit makes a bounded call from the engine node to its
configured Wirekeeper node and requires version 1 with `:send_once`. Direct engine mode skips that
check. Gateway/engine compatibility uses the
existing versioned engine RPC contract. A failed post-activation contract check restores the prior
selected release, including during a component rollback.

The standalone Wirekeeper service loads only `/etc/topics-club/wirekeeper.env`, containing
`RELEASE_NODE`, `RELEASE_COOKIE`, and optionally
`TOPICS_CLUB_WIREKEEPER_MAX_CONNECTIONS`. It does not load `db.env`, `IRC_CREDENTIALS_KEY`, Phoenix,
OAuth, or Web Push secrets. Its systemd unit raises the file-descriptor limit to 65,536. Its health
unit performs a release RPC to `TopicsClub.Wirekeeper.diagnostics/0` and requires transport API
version 1 and the `:send_once` feature.

Erlang distribution is a trusted local boundary in this implementation. Wirekeeper does not add
per-call authentication or authorization beyond the shared node cookie. The first-party topology
therefore binds EPMD and all three distribution ports to loopback and does not support placing the
nodes on separate hosts.

## Not implemented yet

The current umbrella application does not:

- connect to PostgreSQL or assign application meaning to keys;
- implement UDP, a consumer-side TCP/WebSocket listener, or an adapter for the consumer leg;
- register, authenticate, negotiate capabilities, join, part, interpret chat traffic, persist
  messages, or choose reconnect policy;
- persist sockets or replay buffers across loss of the connection process, BEAM node, container, or
  host;
- provide exactly-once inbound transport delivery; selected database effects are idempotent across
  replay, while JOIN alone has generation-local keyed outbound suppression;
- authorize remote engine nodes or expose a versioned command envelope beyond the diagnostics
  compatibility marker;
- preserve a socket across a Wirekeeper node, VM, container, host, or Wirekeeper release restart;
- resume a generation after a replay gap or unavailable checkpoint; or
- participate in the combined Docker/Railway release. Those deployments intentionally retain
  direct Ircxd socket ownership.

Extraction to the standalone repository can happen later. The current boundary deliberately keeps
the app in the umbrella while still packaging it as a separate runtime service.
