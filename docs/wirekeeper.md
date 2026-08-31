# Wirekeeper

Wirekeeper is the `:topics_club_wirekeeper` OTP application under
`apps/topics_club_wirekeeper`. It owns long-lived upstream TCP/TLS connections independently from
the processes that consume their traffic. This lets an engine consumer disappear and reattach
without making consumer loss mean socket loss.

Wirekeeper currently lives inside the TopicsClub umbrella. It has its own application callback,
supervision tree, public API, tests, and no dependencies on the other umbrella applications. It has
not yet been extracted into the separate `wirekeeper` repository.

No other TopicsClub application currently declares Wirekeeper as an umbrella dependency, the IRC
engine does not call it, and none of the `topics_club`, `topics_club_gateway`, or
`topics_club_engine` releases includes it. The root test and documentation tasks do include the
application. Engine integration and production packaging remain later work.

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
opening are cleaned up.

The unique Registry maps a connection key to its connection process and its `:opening`, `:open`, or
`:closed` generation state. Calls do not need to query a potentially busy socket owner merely to
find it.

Each connection GenServer exclusively owns:

- one TCP or TLS socket;
- one opaque integer or non-empty binary key;
- one random 128-bit generation encoded as lowercase hexadecimal;
- adapter module and adapter state;
- an anonymous private ETS `ordered_set` of sequence-numbered binary records;
- delivery credit, cumulative ACK state, and overflow counters; and
- at most one attached local or remote consumer PID.

A connection child is temporary. Wirekeeper never automatically reconnects an upstream connection.
Restarting only the manager leaves established connection processes, sockets, and ETS buffers
intact. Losing the registry owner restarts the later children in the `:rest_for_one` tree, which
closes connections because Wirekeeper can no longer safely enforce unique connection identity.

## Identity and consumer ownership

Opening a key that is opening, open, or retained as a closed tombstone returns
`{:error, :already_open}`; it never replaces the existing socket implicitly. Every attach, detach,
ACK, send, and close operation must include the generation returned by `open/3`. A stale consumer
therefore cannot operate on a replacement socket that reused the same key.

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
| `send_data/3` | Sends iodata upstream through the generation-matched open socket. |
| `close/2` | Explicitly closes and removes the generation-matched connection. |
| `info/1` | Returns one connection's status and bounded counters, but no payloads or credentials. |
| `list/0` | Returns sorted info for current open connections and retained tombstones; openings are omitted. |
| `diagnostics/0` | Aggregates open/closed, attached/detached, buffer, and overflow counts. |

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
```

`attach/3`, `detach/3`, and `ack/4` default their consumer argument to the calling process. Repeating
`attach/3` from the already attached PID is idempotent and does not replay records a second time.

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
| Open options | `:closed_retention_ms` | 60,000 ms |

TCP and TLS use raw binary sockets with active-once reads and finite sends. TCP also enables
`nodelay` and transport keepalive. TLS verifies DNS hostnames and IP subject alternative names by
default; IP literals are connected as addresses rather than sent as IP-valued SNI. Caller-supplied
`:tls_options` may override TLS policy, but Wirekeeper always enforces raw binary mode, passive
setup, and the top-level finite `:send_timeout`.

Public calls convert manager or connection call exits to `{:error, :unavailable}`. This keeps a
temporarily unavailable supervision component distinct from `{:error, :not_found}` and
`{:error, :opening}`.

## Not implemented yet

The current umbrella application does not:

- integrate with `TopicsClub.Engine`, `Ircxd.Client`, or `server_connections`;
- connect to PostgreSQL or assign application meaning to keys;
- implement UDP, a consumer-side TCP/WebSocket listener, or an adapter for the consumer leg;
- register, authenticate, negotiate capabilities, join, part, interpret chat traffic, persist
  messages, or choose reconnect policy;
- persist sockets or replay buffers across loss of the connection process, BEAM node, container, or
  host;
- provide exactly-once delivery;
- authorize remote engine nodes or expose a versioned engine-to-Wirekeeper RPC envelope;
- reconcile application state after `gap?: true`; or
- participate in the combined, gateway-only, or engine-only production releases and their Railway,
  Docker Compose, or systemd deployment definitions.

Extraction to the standalone repository can happen later. Before production packaging, a real
engine session still needs to attach to a kept IRC connection, exchange and ACK traffic, detach, and
resume safely without a second registration or JOIN burst. A continuity-focused deployment must
then place Wirekeeper in a process or service whose lifecycle is not coupled to engine deployments;
co-locating it in the same release cannot preserve sockets across replacement of that release.
