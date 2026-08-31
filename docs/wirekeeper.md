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
- bounded counters for frames and bytes discarded during the current detached episode.

Every attach, send, detach, and close operation must include the current generation. A stale engine
therefore cannot send through, detach, or close a replacement socket using an earlier generation.
Opening a key that is already present is rejected rather than implicitly replacing its socket.

The consumer receives plain messages shaped as:

```elixir
{:topics_club_wirekeeper,
 {:data, %{key: key, generation: generation, payload: bytes}}}

{:topics_club_wirekeeper,
 {:upstream_closed, %{key: key, generation: generation, reason: reason}}}
```

The future engine session can be a process on the same BEAM node or another connected node. The
keeper monitors its PID. Consumer or node loss starts a detached episode without closing the
upstream socket. Reattachment returns the discarded frame count, discarded byte count, and detached
duration before normal relay resumes.

The manager serializes key creation and routing but does not own sockets. Its state is reconstructed
from the dynamic connection supervisor after a manager crash, so restarting this coordination
process leaves established connections intact. The connection supervisor and its connection
processes remain the deliberate socket-lifetime boundary.

## Protocol adapters and IRC PING

`TopicsClub.Wirekeeper.ProtocolAdapter` receives inbound byte chunks and returns ordered actions:

```elixir
{:forward, bytes}
{:reply, bytes}
```

Forward actions go to an attached consumer. While detached, they are drained, discarded, and
counted instead. Reply actions always go directly to the upstream socket, whether a consumer is
attached or not. This is the customization point for maintenance traffic that must outlive the
engine without putting general IRC behavior in the keeper core.

`TopicsClub.Wirekeeper.ProtocolAdapter.IrcKeepalive` provides the required IRC behavior. It:

- frames fragmented socket input into bounded IRC lines;
- recognizes `PING` after valid optional IRCv3 tags and an IRC prefix;
- replies once with `PONG` directly from the socket-owning process;
- does not forward handled `PING` lines, preventing a duplicate engine reply;
- forwards every other complete IRC line byte-for-byte;
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

:ok =
  TopicsClub.Wirekeeper.send_data(
    connection_id,
    opened.generation,
    "NICK example\r\n"
  )
```

TLS uses `{:tls, host: host, port: port}` and verifies peers with the host trust store and hostname
checking by default. Explicit `:tls_options` may refine those defaults for a particular connection.

`list/0`, `info/1`, and `diagnostics/0` expose bounded runtime state without message bodies or IRC
credentials.

## Deliberate exclusions

This application currently does not:

- connect to PostgreSQL or interpret connection keys;
- register, authenticate, join, part, reconnect, or choose IRC policy;
- retain or replay detached application traffic;
- persist sockets or survive its own process/container/host replacement;
- authorize a future remote engine node or define the versioned engine-to-keeper RPC envelope;
- perform engine state snapshotting or reconciliation after a non-zero gap;
- participate in combined, engine-only, Railway, Docker, Compose, or systemd releases.

Those are engine-integration and deployment decisions. They should be added only after a real engine
session can attach to one kept connection, exchange traffic, detach, and safely resume without a
second IRC registration or JOIN burst.
