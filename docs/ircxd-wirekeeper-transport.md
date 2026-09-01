# Ircxd transport boundary for Wirekeeper

## Why Ircxd needed a direct extension

Before this work, `Ircxd.Client` directly opened, read, wrote, and owned its `:gen_tcp` or `:ssl`
socket. TopicsClub could not move socket ownership to Wirekeeper solely from the engine application.

An engine-local TCP proxy would acknowledge a Wirekeeper record after copying bytes to loopback,
not after Ircxd parsed them and the engine processed the resulting events. It would also make a new
Ircxd client repeat IRC registration through a socket that was already registered. The correct
boundary is an optional Ircxd client transport adapter: Ircxd remains the IRC protocol state machine,
while the selected adapter owns connection establishment, framed delivery, acceptance receipts,
writes, and closure.

This support was implemented directly in `~/projects/ircxd` and is pinned here at commit
`ef6645035fcf298d2a8d79ce241b8430bebdd6ee` on the remote `wirekeeper-transport` branch.

## Backward compatibility

The extension is opt-in through `:transport_adapter`. Existing callers use the built-in
`Ircxd.Client.Transport.Socket` adapter, which is the extracted form of the previous connection
code. It preserves existing TCP/TLS options, active-once reads, registration, events, reconnect
behavior, public commands, and `Ircxd.Client.Info.transport` values (`:gen_tcp` or `:ssl`). It starts
no extra process and has no Wirekeeper or TopicsClub dependency.

The same branch adds an independent `:additional_error_numerics` client option. It defaults to an
empty list, so existing Ircxd callers continue to receive unknown vendor numerics as `:raw`.
TopicsClub opts into Solanum numerics `479` and `480`, allowing its existing structured JOIN
failure reconciliation to handle illegal channel names, join throttling, and TLS-only channels.
The normalized selection is part of Ircxd's resume-checkpoint compatibility binding because an
in-progress labeled batch may retain already-classified events. Older checkpoints with no field are
compatible only with the unchanged empty default; changing the selection deliberately rejects the
checkpoint and requires a fresh connection.

A custom adapter receives credential-free endpoint settings in `connect/3`; raw TLS options remain
inside Ircxd. Its `send_data/2` callback does receive complete outbound IRC wire records, including
WEBIRC, PASS, SASL payloads, and later commands. Adapter implementations must protect those bytes in
transit and must never log them.

## Implemented adapter contract

An adapter implements `Ircxd.Client.Transport` and returns one connection mode:

```elixir
{:ok, transport_handle, :fresh}

{:ok, transport_handle,
 {:resumed, protocol_checkpoint, transport_metadata}}

{:error, reason}
```

The handle identifies one connection attempt. Ircxd ignores data and close events from a stale
handle after reconnect. Cleanup failure is terminal for that client attempt; Ircxd does not open a
second handle while an adapter reports that the old one may remain active.

The remaining callbacks are:

- `send_data/2` for serialized outbound IRC records;
- `activate/1` for the next inbound record, a no-op for Wirekeeper's own flow control;
- `checkpoint?/1` to opt into post-record resumable checkpoints;
- `accepted/3` after Ircxd parses a record and emits all of its events;
- `close/2`, which must tolerate concurrent/repeated cleanup; and
- `handle_info/2` for adapter-owned process messages.

An owner delivers one complete IRC record with:

```elixir
Ircxd.Client.Transport.deliver(client, handle, receipt, line)
```

Ircxd parses it, sends its events, calls `accepted/3` with the opaque receipt and complete
post-record checkpoint, then activates the next read. Parse errors are accepted as terminally
consumed records so malformed input is not replayed forever. Upstream closure is reported with
`Ircxd.Client.Transport.closed/3` and follows the existing Ircxd disconnect/reconnect path.

`accepted/3` means Ircxd accepted the record; it does not mean TopicsClub durably processed every
event. The TopicsClub adapter therefore sends an acceptance marker to the same Session PID that
receives Ircxd events. Erlang mailbox ordering guarantees the Session handles preceding events
before that marker, at which point it atomically checkpoints and acknowledges upstream.

## Fresh and resumed clients

For `:fresh`, Ircxd sends its existing WEBIRC, PASS, CAP, NICK, USER, and optional SASL sequence
through `send_data/2`.

For `{:resumed, checkpoint, metadata}`, Ircxd restores the checkpoint and emits, in order:

```elixir
{:connected, connection_metadata}
{:resumed, metadata}
:registered
```

It does not send registration traffic.

The checkpoint is opaque, versioned, integrity-checked, and bounded to 65,536 bytes in its
uncompressed Erlang external-term envelope. It includes all bounded inbound parser state needed to
continue safely: current nickname, negotiated capabilities, ISUPPORT/casemapping, message-ID
deduplication, and active batch, multiline, metadata, labeled-response, and network-batch state.
Deferred server-time buffers and oversized or invalid parser state return
`{:unavailable, reason}` instead of a partial checkpoint.

Outbound command correlation remains process-local because parameters can contain secrets.
Passwords, SASL/WebIRC credentials, raw TLS options, callbacks, PIDs, timers, and private keys are
not retained. The checkpoint binding covers endpoint and parser configuration plus non-secret
authentication/TLS policy. `:resume_binding` may hold a non-secret credential-generation token;
rotating it rejects older checkpoints without retaining the credential itself.

An unknown version, malformed payload, integrity failure, configuration mismatch, replay gap,
missing registered checkpoint, or unavailable checkpoint means the retained generation cannot be
resumed. The owner must close it and establish one fresh IRC connection; it must never send a new
registration sequence through the old registered socket.

## TopicsClub implementation

`TopicsClub.Irc.WirekeeperTransport` selects `server_connections.id` as the opaque key and calls a
local or statically configured distributed Wirekeeper node.

The attached Wirekeeper consumer is the `TopicsClub.Irc.Session` PID—not the Ircxd client PID. The
Session forwards received records to its current Ircxd client using a handle containing node, key,
generation, client, and consumer identity. This gives an Ircxd retry on the same Session the same
durable consumer boundary and makes stale handles harmless.

The adapter performs these transitions:

1. A missing key opens TCP/TLS with Wirekeeper's IRC keepalive adapter, attaches the Session, and
   returns `:fresh`.
2. An existing generation clears a stale attachment for the same Session PID, attaches, and resumes
   only when its summary has no gap and contains a map checkpoint.
3. A gap or missing checkpoint detaches, closes the exact generation, waits for key removal, and
   opens fresh.
4. Each accepted registered record sends an ordered marker; the Session calls
   `ack_with_checkpoint/5`. Pre-registration records use plain `ack/4` because no checkpoint exists.
5. A checkpoint-unavailable result or failed acknowledgement closes the generation.
6. An overflow closes the gapped generation and tells Ircxd the transport failed, forcing a fresh
   IRC connection. It does not attempt targeted reconciliation on the retained socket.
7. An upstream close is reported through Ircxd. A matching abrupt Ircxd client `:DOWN` explicitly
   detaches the Session consumer before retry, resetting in-flight delivery for replay.
8. Engine restart/crash detaches; user QUIT and authoritative connection deletion explicitly close.

On resume the engine restores persisted `joined` memberships into its joined set and persisted
`pending` memberships into both its pending and already-sent sets. The subsequent registered event
therefore does not send duplicate JOIN commands on the retained socket. It proactively sends NAMES
for every confirmed joined membership to rebuild in-memory presence without rejoining.

## Process and deployment boundary

The split topology is gateway → engine → Wirekeeper. All three BEAM nodes are on one host, share a
distribution cookie, and bind EPMD/distribution to loopback. Gateway never calls Wirekeeper.

Restarting only the engine replaces its Session and Ircxd processes while Wirekeeper retains IRC
sockets, PING/PONG handling, bounded records, and parser checkpoints. Restarting Wirekeeper itself
necessarily loses those memory-only sockets. The engine can explicitly select `direct` mode, and
the combined release remains direct by default.

## Verification in this repository

Current automated coverage proves:

- unchanged default Ircxd TCP/TLS behavior and optional custom adapters in the Ircxd project;
- unchanged raw handling for vendor numerics unless a caller explicitly opts into selected generic
  errors, including checkpoint mismatch coverage when that selection changes;
- fresh registration writes and resumed parser restoration without registration writes;
- stale transport handles and cleanup fencing;
- bounded, credential-free checkpoints including in-progress parser/batch state;
- a real engine Session scenario shared by direct and Wirekeeper modes;
- persistence-before-ACK through the Session mailbox;
- engine Session replacement and abrupt Ircxd client retry with ordered replay;
- no repeated PASS/CAP/SASL/NICK/USER/JOIN on resume;
- gap/overflow and unavailable-checkpoint fallback to a fresh generation; and
- authoritative deletion cleanup of the retained Wirekeeper generation.
