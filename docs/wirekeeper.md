# Connection keeper

`topics_club_wirekeeper` is an independent umbrella application for owning long-lived upstream
TCP/TLS connections separately from the processes that consume their traffic. It is deliberately
not integrated with the IRC engine and is not included in any production release yet.

Deployment packaging is deferred until the engine integration establishes both required runtime
forms:

- combined hosting can run the keeper in the same release when connection continuity across a
  whole-container replacement is not promised;
- continuity-focused hosting must run the keeper in a separate operating-system process or
  service whose lifecycle is not coupled to engine or gateway deployments.

Adding the application to the current combined, engine, Railway, or Docker Compose artifacts before
that choice would create deployment shape without proving the consumer contract.

## Ownership contract

Each open connection has:

- an opaque integer or binary key selected by the caller;
- a random generation unique to that opening of the key;
- one TCP or TLS socket owned exclusively by a keeper connection process;
- at most one attached local or remote consumer PID;
- protocol-adapter state;
- a private OTP ETS `ordered_set` containing complete, sequence-numbered protocol records;
- record-count and byte-count limits, an in-flight delivery window, and explicit overflow counters.

Every attach, send, detach, and close operation must include the current generation. A stale engine
therefore cannot send through, detach, or close a replacement socket using an earlier generation.
Opening a key that is already present is rejected rather than implicitly replacing its socket.

The consumer receives plain messages shaped as:

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
    total_dropped_records: records,
    total_dropped_bytes: bytes
  }}}

{:topics_club_wirekeeper,
 {:upstream_closed, %{key: key, generation: generation, reason: reason}}}
```

The future engine session can be a process on the same BEAM node or another connected node. The
keeper monitors its PID. Consumer or node loss starts a detached episode without closing the
upstream socket. Complete adapter records remain in ETS while detached. Reattachment reports the
records available for replay, any records evicted by the configured bounds, and detached duration.

Delivery is deliberately **bounded at-least-once**, not exactly-once. Each record has a monotonic
sequence scoped to one connection generation. The keeper retains records until the attached consumer
cumulatively acknowledges their sequence with `ack/4`. If that consumer exits or detaches first, the
next consumer receives the unacknowledged records again. Consumers must therefore process records
idempotently. At most `:max_in_flight` unacknowledged records are placed in a consumer mailbox at once;
ACKs release credit for later records.

The buffer uses an anonymous private ETS table owned by the socket process. It adds no dependency and
keeps message bodies outside manager state. It is intentionally memory-only: losing the keeper
connection process also loses its socket, so Mnesia or disk persistence would not preserve the TCP
session it belonged to. Defaults are 1,000 records, 1 MiB, and 64 in-flight records per connection;
`:buffer` accepts `:max_records`, `:max_bytes`, and `:max_in_flight`. Overflow evicts the oldest
retained complete records and sets `gap?: true`; a single record larger than the byte limit is rejected
without evicting retained records.

If the upstream closes while detached or records remain unacknowledged, the connection becomes a
closed tombstone. It retains the bounded buffer and close reason for `:closed_retention_ms` (60 seconds
by default). Reattachment delivers records before the close event. The tombstone disappears after the
last ACK or when its retention timer expires.

The manager serializes key reservations but performs network connection work in supervised tasks, so
one slow dial or TLS handshake cannot block routing. A unique OTP Registry indexes connection identity
without calling potentially busy socket owners. Registry and connection-supervisor lifecycles are
coupled with `:rest_for_one`; manager restarts leave both established connections and their ETS buffers
intact, while registry loss closes the sockets whose identity it could no longer safely enforce.

## Protocol adapters and IRC PING

`TopicsClub.Wirekeeper.ProtocolAdapter` receives inbound byte chunks and returns ordered actions:

```elixir
{:forward, bytes}
{:reply, bytes}
```

Every forward action is one complete protocol record. The connection layer assigns its sequence and
stores it in ETS before bounded delivery; it does not need to know the record's protocol. Reply actions
always go directly to the upstream socket, whether a consumer is attached or not. This is the
customization point for framing and maintenance traffic that must outlive the engine without putting
general IRC behavior in the keeper core.

`TopicsClub.Wirekeeper.ProtocolAdapter.IrcKeepalive` provides the required IRC behavior. It:

- frames fragmented socket input into bounded IRC lines;
- recognizes `PING` after valid optional IRCv3 tags and an IRC prefix;
- replies once with `PONG` directly from the socket-owning process;
- does not forward handled `PING` lines, preventing a duplicate engine reply;
- emits every other complete IRC line byte-for-byte as a separate buffer record;
- closes only the affected connection if an unterminated line exceeds the configured bound.

The passthrough adapter is available for protocols that do not require socket-layer maintenance.
Additional protocol behavior belongs in focused adapters, not conditionals in the connection owner.

## Current API

The public entry point is `TopicsClub.Wirekeeper`:

```elixir
{:ok, opened} =
  TopicsClub.Wirekeeper.open(
    connection_id,
    {:tcp, host: "irc.example.net", port: 6667},
    protocol_adapter: {TopicsClub.Wirekeeper.ProtocolAdapter.IrcKeepalive, []}
  )

{:ok, gap} =
  TopicsClub.Wirekeeper.attach(connection_id, opened.generation, self())

receive do
  {:topics_club_wirekeeper, {:data, %{sequence: sequence, payload: line}}} ->
    process_irc_line(line)
    :ok = TopicsClub.Wirekeeper.ack(connection_id, opened.generation, sequence)
end

:ok =
  TopicsClub.Wirekeeper.send_data(
    connection_id,
    opened.generation,
    "NICK example\r\n"
  )
```

TLS uses `{:tls, host: host, port: port}` and verifies peers with the host trust store and hostname
checking by default, including IP subject-alternative-name verification without sending IP-valued SNI.
Explicit `:tls_options` may refine those defaults for a particular connection. TCP and TLS writes use
a finite five-second send timeout by default; `:send_timeout` may shorten or extend it.

`info/1` and the tagged results from `list/0` and `diagnostics/0` expose bounded
record/byte/overflow runtime state without message bodies or IRC credentials. Manager or connection
call failures return `{:error, :unavailable}` rather than being misreported as missing connections.

## Deliberate exclusions

This application currently does not:

- connect to PostgreSQL or interpret connection keys;
- register, authenticate, join, part, reconnect, or choose IRC policy;
- persist buffers across loss of the keeper connection process, container, or host;
- provide exactly-once delivery (consumer ACKs provide bounded at-least-once delivery);
- persist sockets or survive its own process/container/host replacement;
- authorize a future remote engine node or define the versioned engine-to-keeper RPC envelope;
- hide bounded-buffer overflow; the future engine must reconcile after `gap?: true`;
- participate in combined, engine-only, Railway, Docker, Compose, or systemd releases.

Those are engine-integration and deployment decisions. They should be added only after a real engine
session can attach to one kept connection, exchange traffic, detach, and safely resume without a
second IRC registration or JOIN burst.
