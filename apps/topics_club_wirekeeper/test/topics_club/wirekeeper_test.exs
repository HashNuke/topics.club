defmodule TopicsClub.WirekeeperTest do
  use ExUnit.Case, async: false

  alias TopicsClub.Wirekeeper
  alias TopicsClub.Wirekeeper.ClosingTcpServer
  alias TopicsClub.Wirekeeper.Manager
  alias TopicsClub.Wirekeeper.NonReadingTcpServer
  alias TopicsClub.Wirekeeper.ProtocolAdapter.IrcKeepalive
  alias TopicsClub.Wirekeeper.RelayConsumer
  alias TopicsClub.Wirekeeper.TestTcpServer

  test "keeps one TCP connection across detach and reattach while answering IRC PING" do
    server = start_supervised!({TestTcpServer, self()})
    key = unique_key("detach")

    assert {:ok, opened} = open_tcp(key, server, protocol_adapter: {IrcKeepalive, []})
    on_exit(fn -> Wirekeeper.close(key, opened.generation) end)

    assert_receive {:wirekeeper_test_server, :accepted, ^server, 1}
    assert {:ok, initial_gap} = Wirekeeper.attach(key, opened.generation, self())
    assert initial_gap.replayed_records == 0

    inbound = ":irc.example NOTICE keeper :attached\r\n"
    assert :ok = TestTcpServer.send_data(server, inbound)

    assert_receive {:topics_club_wirekeeper,
                    {:data,
                     %{
                       key: ^key,
                       generation: opened_generation,
                       sequence: inbound_sequence,
                       payload: ^inbound
                     }}}

    assert opened_generation == opened.generation
    assert :ok = Wirekeeper.ack(key, opened.generation, inbound_sequence)

    outbound = "PRIVMSG #elixir :hello upstream\r\n"
    assert :ok = Wirekeeper.send_data(key, opened.generation, outbound)
    assert_server_data(server, outbound)

    assert :ok = Wirekeeper.detach(key, opened.generation, self())

    buffered = ":friend!u@h PRIVMSG #elixir :during restart\r\n"
    ping = "@label=keepalive :irc.example PING :token-42\r\n"
    assert :ok = TestTcpServer.send_data(server, buffered <> ping)
    assert_server_data(server, "PONG :token-42\r\n")
    refute_receive {:topics_club_wirekeeper, {:data, _event}}, 50

    assert {:ok, replay} = Wirekeeper.attach(key, opened.generation, self())
    refute replay.gap?
    assert replay.replayed_records == 1
    assert replay.replayed_bytes == byte_size(buffered)
    assert replay.detached_for_ms >= 0

    assert_receive {:topics_club_wirekeeper, {:data, %{sequence: sequence, payload: ^buffered}}}

    assert :ok = Wirekeeper.ack(key, opened.generation, sequence)
    assert TestTcpServer.connection_count(server) == 1
  end

  test "buffers detached IRC records separately and replays them in order" do
    server = start_supervised!({TestTcpServer, self()})
    key = unique_key("buffered-records")

    assert {:ok, opened} = open_tcp(key, server, protocol_adapter: {IrcKeepalive, []})
    on_exit(fn -> Wirekeeper.close(key, opened.generation) end)
    assert_receive {:wirekeeper_test_server, :accepted, ^server, 1}

    first = ":friend!u@h PRIVMSG #elixir :first while detached\r\n"
    second = ":friend!u@h NOTICE #elixir :second while detached\r\n"
    ping = ":irc.example PING :buffer-token\r\n"

    assert :ok = TestTcpServer.send_data(server, first <> ping <> second)
    assert_server_data(server, "PONG :buffer-token\r\n")
    assert {:ok, info} = await_buffered_records(key, 2)
    assert info.buffered_bytes == byte_size(first) + byte_size(second)

    assert {:ok, replay} = Wirekeeper.attach(key, opened.generation, self())
    assert replay.replayed_records == 2
    assert replay.replayed_bytes == byte_size(first) + byte_size(second)
    assert replay.delivery_guarantee == :at_least_once
    refute replay.gap?

    assert_receive {:topics_club_wirekeeper,
                    {:data, %{sequence: first_sequence, payload: ^first}}}

    assert_receive {:topics_club_wirekeeper,
                    {:data, %{sequence: second_sequence, payload: ^second}}}

    assert second_sequence > first_sequence
    refute_receive {:topics_club_wirekeeper, {:data, %{payload: ^ping}}}
    assert {:ok, %{buffered_records: 2}} = Wirekeeper.info(key)
    assert :ok = Wirekeeper.ack(key, opened.generation, second_sequence)
    assert {:ok, %{buffered_records: 0, buffered_bytes: 0}} = Wirekeeper.info(key)
  end

  test "keeps a fragmented IRC record whole when it completes while detached" do
    server = start_supervised!({TestTcpServer, self()})
    key = unique_key("fragmented-record")

    assert {:ok, opened} = open_tcp(key, server, protocol_adapter: {IrcKeepalive, []})
    on_exit(fn -> Wirekeeper.close(key, opened.generation) end)
    assert_receive {:wirekeeper_test_server, :accepted, ^server, 1}
    assert {:ok, _replay} = Wirekeeper.attach(key, opened.generation, self())

    prefix = ":friend!u@h PRIVMSG #elixir :split"
    suffix = " across detach\r\n"
    complete = prefix <> suffix

    assert :ok = TestTcpServer.send_data(server, prefix)
    assert {:ok, connection} = Manager.lookup(key)
    assert :ok = await_adapter_buffer(connection, prefix)
    refute_receive {:topics_club_wirekeeper, {:data, _event}}

    assert :ok = Wirekeeper.detach(key, opened.generation, self())
    assert :ok = TestTcpServer.send_data(server, suffix)
    assert {:ok, _info} = await_buffered_records(key, 1)

    assert {:ok, %{replayed_records: 1, gap?: false}} =
             Wirekeeper.attach(key, opened.generation, self())

    assert_receive {:topics_club_wirekeeper, {:data, %{sequence: sequence, payload: ^complete}}}

    assert :ok = Wirekeeper.ack(key, opened.generation, sequence)
    refute_receive {:topics_club_wirekeeper, {:data, _event}}
  end

  test "does not let a boundary-spanning IRC record overtake buffered records" do
    server = start_supervised!({TestTcpServer, self()})
    key = unique_key("attachment-boundary")

    assert {:ok, opened} =
             open_tcp(key, server,
               protocol_adapter: {IrcKeepalive, []},
               buffer: [max_records: 10, max_bytes: 1_024, max_in_flight: 1]
             )

    on_exit(fn -> Wirekeeper.close(key, opened.generation) end)
    assert_receive {:wirekeeper_test_server, :accepted, ^server, 1}
    first = ":server NOTICE nick :already buffered\r\n"
    prefix = ":server NOTICE nick :crosses"
    suffix = " attachment boundary\r\n"
    second = prefix <> suffix

    assert :ok = TestTcpServer.send_data(server, first <> prefix)
    assert {:ok, connection} = Manager.lookup(key)
    assert :ok = await_adapter_buffer(connection, prefix)
    assert {:ok, _info} = await_buffered_records(key, 1)
    assert {:ok, %{replayed_records: 1}} = Wirekeeper.attach(key, opened.generation, self())

    assert_receive {:topics_club_wirekeeper,
                    {:data, %{sequence: first_sequence, payload: ^first}}}

    assert :ok = TestTcpServer.send_data(server, suffix)
    assert {:ok, _info} = await_buffered_records(key, 2)
    refute_receive {:topics_club_wirekeeper, {:data, %{payload: ^second}}}
    assert :ok = Wirekeeper.ack(key, opened.generation, first_sequence)

    assert_receive {:topics_club_wirekeeper,
                    {:data, %{sequence: second_sequence, payload: ^second}}}

    assert second_sequence > first_sequence
    assert :ok = Wirekeeper.ack(key, opened.generation, second_sequence)
  end

  test "answers a fragmented detached PING without buffering it" do
    server = start_supervised!({TestTcpServer, self()})
    key = unique_key("fragmented-ping")

    assert {:ok, opened} = open_tcp(key, server, protocol_adapter: {IrcKeepalive, []})
    on_exit(fn -> Wirekeeper.close(key, opened.generation) end)
    assert_receive {:wirekeeper_test_server, :accepted, ^server, 1}
    assert {:ok, connection} = Manager.lookup(key)
    prefix = "@label=42 :irc.example PI"

    assert :ok = TestTcpServer.send_data(server, prefix)
    assert :ok = await_adapter_buffer(connection, prefix)
    assert :ok = TestTcpServer.send_data(server, "NG :fragmented-token\r\n")
    assert_server_data(server, "PONG :fragmented-token\r\n")
    assert {:ok, %{buffered_records: 0, buffered_bytes: 0}} = Wirekeeper.info(key)
  end

  test "retains complete IRC records that precede a terminal protocol error" do
    server = start_supervised!({TestTcpServer, self()})
    key = unique_key("record-before-protocol-error")

    assert {:ok, opened} =
             open_tcp(key, server,
               protocol_adapter: {IrcKeepalive, max_line_bytes: 32},
               closed_retention_ms: 5_000
             )

    assert_receive {:wirekeeper_test_server, :accepted, ^server, 1}
    valid = ":s NOTICE n :ok\r\n"
    oversized_tail = String.duplicate("x", 33)
    assert :ok = TestTcpServer.send_data(server, valid <> oversized_tail)

    assert {:ok,
            %{
              status: :closed,
              upstream_closed_reason: {:protocol_error, :line_too_long},
              buffered_records: 1
            }} = await_connection_status(key, :closed)

    assert {:ok, %{replayed_records: 1}} = Wirekeeper.attach(key, opened.generation, self())

    assert_receive {:topics_club_wirekeeper, {:data, %{sequence: sequence, payload: ^valid}}}

    assert_receive {:topics_club_wirekeeper,
                    {:upstream_closed,
                     %{
                       key: ^key,
                       generation: generation,
                       reason: {:protocol_error, :line_too_long}
                     }}}

    assert generation == opened.generation
    assert :ok = Wirekeeper.ack(key, opened.generation, sequence)
    assert {:error, :not_found} = await_missing_connection(key)
  end

  test "bounds detached records by evicting the oldest complete record and reports the gap" do
    server = start_supervised!({TestTcpServer, self()})
    key = unique_key("bounded-buffer")

    assert {:ok, opened} =
             open_tcp(key, server,
               protocol_adapter: {IrcKeepalive, []},
               buffer: [max_records: 2, max_bytes: 1_024]
             )

    on_exit(fn -> Wirekeeper.close(key, opened.generation) end)
    assert_receive {:wirekeeper_test_server, :accepted, ^server, 1}

    first = ":server NOTICE nick :first\r\n"
    second = ":server NOTICE nick :second\r\n"
    third = ":server NOTICE nick :third\r\n"

    assert :ok = TestTcpServer.send_data(server, first <> second <> third)
    assert {:ok, info} = await_buffered_records(key, 2)
    assert info.dropped_records == 1
    assert info.dropped_bytes == byte_size(first)

    assert {:ok, replay} = Wirekeeper.attach(key, opened.generation, self())
    assert replay.gap?
    assert replay.replayed_records == 2
    assert replay.dropped_records == 1
    assert replay.dropped_bytes == byte_size(first)

    assert_receive {:topics_club_wirekeeper,
                    {:data, %{sequence: second_sequence, payload: ^second}}}

    assert_receive {:topics_club_wirekeeper,
                    {:data, %{sequence: third_sequence, payload: ^third}}}

    assert :ok = Wirekeeper.ack(key, opened.generation, third_sequence)
    assert third_sequence > second_sequence
    refute_receive {:topics_club_wirekeeper, {:data, %{payload: ^first}}}
  end

  test "bounds detached records by bytes as well as record count" do
    server = start_supervised!({TestTcpServer, self()})
    key = unique_key("byte-bounded-buffer")
    first = ":server NOTICE nick :aaaaa\r\n"
    second = ":server NOTICE nick :bbbbb\r\n"
    third = ":server NOTICE nick :ccccc\r\n"

    assert byte_size(first) == byte_size(second)
    assert byte_size(second) == byte_size(third)

    assert {:ok, opened} =
             open_tcp(key, server,
               protocol_adapter: {IrcKeepalive, []},
               buffer: [max_records: 10, max_bytes: byte_size(second) + byte_size(third)]
             )

    on_exit(fn -> Wirekeeper.close(key, opened.generation) end)
    assert_receive {:wirekeeper_test_server, :accepted, ^server, 1}
    assert :ok = TestTcpServer.send_data(server, first <> second <> third)

    assert {:ok, %{buffered_records: 2, dropped_records: 1}} =
             await_buffered_records(key, 2)

    assert {:ok, %{replayed_records: 2, dropped_records: 1, gap?: true}} =
             Wirekeeper.attach(key, opened.generation, self())

    assert_receive {:topics_club_wirekeeper,
                    {:data, %{sequence: second_sequence, payload: ^second}}}

    assert_receive {:topics_club_wirekeeper,
                    {:data, %{sequence: third_sequence, payload: ^third}}}

    assert :ok = Wirekeeper.ack(key, opened.generation, third_sequence)
    assert third_sequence > second_sequence
    refute_receive {:topics_club_wirekeeper, {:data, %{payload: ^first}}}
  end

  test "redelivers unacknowledged records after a replay consumer crashes" do
    server = start_supervised!({TestTcpServer, self()})
    first_consumer = start_supervised!({RelayConsumer, self()})
    key = unique_key("at-least-once")

    assert {:ok, opened} =
             open_tcp(key, server,
               protocol_adapter: {IrcKeepalive, []},
               buffer: [max_records: 10, max_bytes: 1_024, max_in_flight: 1]
             )

    on_exit(fn -> Wirekeeper.close(key, opened.generation) end)
    assert_receive {:wirekeeper_test_server, :accepted, ^server, 1}
    first = ":server NOTICE nick :one\r\n"
    second = ":server NOTICE nick :two\r\n"
    third = ":server NOTICE nick :three\r\n"
    assert :ok = TestTcpServer.send_data(server, first <> second <> third)
    assert {:ok, _info} = await_buffered_records(key, 3)

    assert {:ok, %{delivery_guarantee: :at_least_once}} =
             Wirekeeper.attach(key, opened.generation, first_consumer)

    assert_receive {:relay_consumer, ^first_consumer,
                    {:topics_club_wirekeeper,
                     {:data, %{sequence: first_sequence, payload: ^first}}}}

    first_consumer_ref = Process.monitor(first_consumer)
    GenServer.stop(first_consumer)
    assert_receive {:DOWN, ^first_consumer_ref, :process, ^first_consumer, :normal}
    assert {:ok, %{attached?: false}} = await_detached_connection(key)

    assert {:ok, _replay} = Wirekeeper.attach(key, opened.generation, self())

    assert_receive {:topics_club_wirekeeper,
                    {:data, %{sequence: ^first_sequence, payload: ^first}}}

    assert :ok = Wirekeeper.ack(key, opened.generation, first_sequence)

    assert_receive {:topics_club_wirekeeper,
                    {:data, %{sequence: second_sequence, payload: ^second}}}

    assert :ok = Wirekeeper.ack(key, opened.generation, second_sequence)

    assert_receive {:topics_club_wirekeeper,
                    {:data, %{sequence: third_sequence, payload: ^third}}}

    assert :ok = Wirekeeper.ack(key, opened.generation, third_sequence)
    assert first_sequence < second_sequence and second_sequence < third_sequence
    assert {:ok, %{buffered_records: 0}} = Wirekeeper.info(key)
  end

  test "evicted delivered records retain credit and overflow signals are coalesced" do
    server = start_supervised!({TestTcpServer, self()})
    consumer = start_supervised!({RelayConsumer, self()})
    key = unique_key("bounded-credit")

    assert {:ok, opened} =
             open_tcp(key, server,
               protocol_adapter: {IrcKeepalive, []},
               buffer: [max_records: 2, max_bytes: 1_024, max_in_flight: 1]
             )

    on_exit(fn -> Wirekeeper.close(key, opened.generation) end)
    assert_receive {:wirekeeper_test_server, :accepted, ^server, 1}
    assert {:ok, _replay} = Wirekeeper.attach(key, opened.generation, consumer)

    lines = Enum.map(1..10, &":server NOTICE nick :record-#{&1}\r\n")
    assert :ok = TestTcpServer.send_data(server, Enum.join(lines))

    first = hd(lines)

    assert_receive {:relay_consumer, ^consumer,
                    {:topics_club_wirekeeper,
                     {:data, %{sequence: first_sequence, payload: ^first}}}}

    assert_receive {:relay_consumer, ^consumer,
                    {:topics_club_wirekeeper,
                     {:overflow, %{dropped_records: 1, dropped_bytes: dropped_bytes}}}}

    assert dropped_bytes == byte_size(first)
    assert {:ok, info} = await_dropped_records(key, 8)
    assert info.buffered_records == 2
    assert info.in_flight_records == 1
    refute_receive {:relay_consumer, ^consumer, {:topics_club_wirekeeper, _event}}

    assert :ok = Wirekeeper.ack(key, opened.generation, first_sequence, consumer)
    ninth = Enum.at(lines, 8)

    assert_receive {:relay_consumer, ^consumer,
                    {:topics_club_wirekeeper,
                     {:data, %{sequence: ninth_sequence, payload: ^ninth}}}}

    assert ninth_sequence > first_sequence
  end

  test "preserves overflow evidence when the first replay consumer dies" do
    server = start_supervised!({TestTcpServer, self()})
    first_consumer = start_supervised!({RelayConsumer, self()})
    key = unique_key("persistent-gap")

    assert {:ok, opened} =
             open_tcp(key, server,
               protocol_adapter: {IrcKeepalive, []},
               buffer: [max_records: 1, max_bytes: 1_024, max_in_flight: 1]
             )

    on_exit(fn -> Wirekeeper.close(key, opened.generation) end)
    assert_receive {:wirekeeper_test_server, :accepted, ^server, 1}
    first = ":server NOTICE nick :dropped\r\n"
    second = ":server NOTICE nick :retained\r\n"
    assert :ok = TestTcpServer.send_data(server, first <> second)
    assert {:ok, %{buffered_records: 1, dropped_records: 1}} = await_buffered_records(key, 1)

    assert {:ok, first_replay} = Wirekeeper.attach(key, opened.generation, first_consumer)
    assert first_replay.gap?
    assert first_replay.dropped_records == 1

    assert {:ok, retry_summary} = Wirekeeper.attach(key, opened.generation, first_consumer)
    assert retry_summary.gap?
    assert retry_summary.dropped_records == 1
    assert retry_summary.dropped_bytes == byte_size(first)
    assert retry_summary.replayed_records == 0

    first_consumer_ref = Process.monitor(first_consumer)
    GenServer.stop(first_consumer)
    assert_receive {:DOWN, ^first_consumer_ref, :process, ^first_consumer, :normal}
    assert {:ok, %{attached?: false}} = await_detached_connection(key)

    assert {:ok, second_replay} = Wirekeeper.attach(key, opened.generation, self())
    assert second_replay.gap?
    assert second_replay.dropped_records == 1
    assert second_replay.dropped_bytes == byte_size(first)
  end

  test "accepts cumulative ACK retries after a same-consumer replay duplicate" do
    server = start_supervised!({TestTcpServer, self()})
    key = unique_key("idempotent-ack")

    assert {:ok, opened} =
             open_tcp(key, server,
               protocol_adapter: {IrcKeepalive, []},
               buffer: [max_records: 10, max_bytes: 1_024, max_in_flight: 1]
             )

    on_exit(fn -> Wirekeeper.close(key, opened.generation) end)
    assert_receive {:wirekeeper_test_server, :accepted, ^server, 1}
    assert {:ok, _replay} = Wirekeeper.attach(key, opened.generation, self())
    line = ":server NOTICE nick :ack me\r\n"
    assert :ok = TestTcpServer.send_data(server, line)

    assert_receive {:topics_club_wirekeeper, {:data, %{sequence: sequence, payload: ^line}}}

    assert :ok = Wirekeeper.detach(key, opened.generation, self())
    assert {:ok, _replay} = Wirekeeper.attach(key, opened.generation, self())

    assert_receive {:topics_club_wirekeeper, {:data, %{sequence: ^sequence, payload: ^line}}}

    assert :ok = Wirekeeper.ack(key, opened.generation, sequence)
    assert :ok = Wirekeeper.ack(key, opened.generation, sequence)
    assert {:ok, %{acked_through: ^sequence, buffered_records: 0}} = Wirekeeper.info(key)
  end

  test "retains buffered records and the close reason until a detached consumer returns" do
    server = start_supervised!({TestTcpServer, self()})
    key = unique_key("detached-close")

    assert {:ok, opened} =
             open_tcp(key, server,
               protocol_adapter: {IrcKeepalive, []},
               closed_retention_ms: 5_000
             )

    assert_receive {:wirekeeper_test_server, :accepted, ^server, 1}
    buffered = ":server NOTICE nick :last record before close\r\n"
    assert :ok = TestTcpServer.send_data(server, buffered)
    assert {:ok, _info} = await_buffered_records(key, 1)
    assert :ok = TestTcpServer.close_clients(server)

    assert {:ok, %{status: :closed, upstream_closed_reason: :closed}} =
             await_connection_status(key, :closed)

    assert {:ok, %{replayed_records: 1}} = Wirekeeper.attach(key, opened.generation, self())
    assert_receive {:topics_club_wirekeeper, {:data, %{sequence: sequence, payload: ^buffered}}}

    assert_receive {:topics_club_wirekeeper,
                    {:upstream_closed, %{key: ^key, generation: generation, reason: :closed}}}

    assert generation == opened.generation
    assert :ok = Wirekeeper.ack(key, opened.generation, sequence)
    assert {:error, :not_found} = await_missing_connection(key)
  end

  test "removes an empty closed tombstone as soon as its consumer observes closure" do
    server = start_supervised!({TestTcpServer, self()})
    key = unique_key("empty-detached-close")

    assert {:ok, opened} = open_tcp(key, server, closed_retention_ms: 5_000)
    assert_receive {:wirekeeper_test_server, :accepted, ^server, 1}
    assert :ok = TestTcpServer.close_clients(server)
    assert {:ok, %{status: :closed}} = await_connection_status(key, :closed)

    assert {:ok, %{replayed_records: 0}} = Wirekeeper.attach(key, opened.generation, self())

    assert_receive {:topics_club_wirekeeper,
                    {:upstream_closed, %{key: ^key, generation: generation, reason: :closed}}}

    assert generation == opened.generation
    assert {:error, :not_found} = await_missing_connection(key)
    assert {:ok, reopened} = open_tcp(key, server)
    on_exit(fn -> Wirekeeper.close(key, reopened.generation) end)
    assert_receive {:wirekeeper_test_server, :accepted, ^server, 1}
  end

  test "rejects stale generations and a second attached consumer" do
    server = start_supervised!({TestTcpServer, self()})
    key = unique_key("generation")

    assert {:ok, opened} = open_tcp(key, server)
    on_exit(fn -> Wirekeeper.close(key, opened.generation) end)
    assert_receive {:wirekeeper_test_server, :accepted, ^server, 1}

    stale_generation = String.duplicate("0", 32)
    assert {:error, :stale_generation} = Wirekeeper.attach(key, stale_generation, self())
    assert {:error, :stale_generation} = Wirekeeper.send_data(key, stale_generation, "NOOP\r\n")
    assert {:error, :stale_generation} = Wirekeeper.close(key, stale_generation)
    assert {:error, :already_open} = open_tcp(key, server)

    assert {:ok, _gap} = Wirekeeper.attach(key, opened.generation, self())

    other_consumer = spawn(fn -> receive do: (:stop -> :ok) end)
    on_exit(fn -> send(other_consumer, :stop) end)

    assert {:error, :already_attached} =
             Wirekeeper.attach(key, opened.generation, other_consumer)
  end

  test "rejects a nil detach consumer without crashing the detached connection" do
    server = start_supervised!({TestTcpServer, self()})
    key = unique_key("nil-detach")

    assert {:ok, opened} = open_tcp(key, server)
    on_exit(fn -> Wirekeeper.close(key, opened.generation) end)
    assert_receive {:wirekeeper_test_server, :accepted, ^server, 1}

    assert {:error, :invalid_consumer} = Wirekeeper.detach(key, opened.generation, nil)
    assert {:ok, %{generation: generation, attached?: false}} = Wirekeeper.info(key)
    assert generation == opened.generation
    assert TestTcpServer.connection_count(server) == 1
  end

  test "a consumer crash detaches without closing the upstream connection" do
    server = start_supervised!({TestTcpServer, self()})
    consumer = start_supervised!({Agent, fn -> :consumer end})
    key = unique_key("consumer")

    assert {:ok, opened} = open_tcp(key, server)
    on_exit(fn -> Wirekeeper.close(key, opened.generation) end)
    assert_receive {:wirekeeper_test_server, :accepted, ^server, 1}
    assert {:ok, _gap} = Wirekeeper.attach(key, opened.generation, consumer)

    consumer_ref = Process.monitor(consumer)
    GenServer.stop(consumer)
    assert_receive {:DOWN, ^consumer_ref, :process, ^consumer, :normal}
    assert {:ok, %{attached?: false}} = await_detached_connection(key)

    buffered = "traffic after consumer crash\r\n"
    assert :ok = TestTcpServer.send_data(server, buffered)
    assert {:ok, %{buffered_records: 1}} = await_buffered_records(key, 1)
    assert {:ok, replay} = Wirekeeper.attach(key, opened.generation, self())
    refute replay.gap?
    assert replay.replayed_records == 1
    assert replay.replayed_bytes == byte_size(buffered)

    assert_receive {:topics_club_wirekeeper, {:data, %{sequence: sequence, payload: ^buffered}}}

    assert :ok = Wirekeeper.ack(key, opened.generation, sequence)
    assert TestTcpServer.connection_count(server) == 1
  end

  test "a manager crash preserves its owned TCP connections and reconstructs routing" do
    server = start_supervised!({TestTcpServer, self()})
    key = unique_key("manager")

    assert {:ok, opened} = open_tcp(key, server)
    on_exit(fn -> Wirekeeper.close(key, opened.generation) end)
    assert_receive {:wirekeeper_test_server, :accepted, ^server, 1}

    assert {:ok, connection} = Manager.lookup(key)
    manager = Process.whereis(Manager)
    manager_ref = Process.monitor(manager)
    Process.exit(manager, :kill)
    assert_receive {:DOWN, ^manager_ref, :process, ^manager, :killed}

    replacement = await_named_process(Manager, manager)
    _ = :sys.get_state(replacement)

    assert {:ok, ^connection} = Manager.lookup(key)
    assert TestTcpServer.connection_count(server) == 1
    assert {:ok, _gap} = Wirekeeper.attach(key, opened.generation, self())

    payload = "manager recovered\r\n"
    assert :ok = TestTcpServer.send_data(server, payload)

    assert_receive {:topics_club_wirekeeper,
                    {:data, %{key: ^key, generation: generation, payload: ^payload}}}

    assert generation == opened.generation
  end

  test "a manager restart cannot lose a busy connection identity and open a duplicate key" do
    server = start_supervised!({TestTcpServer, self()})
    key = unique_key("busy-manager-rebuild")

    assert {:ok, opened} = open_tcp(key, server)
    on_exit(fn -> Wirekeeper.close(key, opened.generation) end)
    assert_receive {:wirekeeper_test_server, :accepted, ^server, 1}
    assert {:ok, connection} = Manager.lookup(key)
    :ok = :sys.suspend(connection)

    on_exit(fn ->
      try do
        :sys.resume(connection)
      catch
        :exit, _reason -> :ok
      end
    end)

    manager = Process.whereis(Manager)
    manager_ref = Process.monitor(manager)
    Process.exit(manager, :kill)
    assert_receive {:DOWN, ^manager_ref, :process, ^manager, :killed}

    replacement = await_named_process(Manager, manager)
    _state = :sys.get_state(replacement, 6_000)
    :ok = :sys.resume(connection)

    assert {:error, :already_open} = open_tcp(key, server)
    assert {:ok, ^connection} = Manager.lookup(key)
    assert TestTcpServer.connection_count(server) == 1
  end

  test "a slow connection open does not block routing for established connections" do
    server = start_supervised!({TestTcpServer, self()})

    stalled_server =
      start_supervised!(
        Supervisor.child_spec({TestTcpServer, self()}, id: {:stalled_tcp_server, self()})
      )

    key = unique_key("responsive-manager")
    slow_key = unique_key("slow-open")

    assert {:ok, opened} = open_tcp(key, server)
    on_exit(fn -> Wirekeeper.close(key, opened.generation) end)
    assert_receive {:wirekeeper_test_server, :accepted, ^server, 1}
    test_process = self()

    _open_task =
      start_supervised!(
        Supervisor.child_spec(
          {Task,
           fn ->
             result =
               Wirekeeper.open(
                 slow_key,
                 {:tls,
                  host: "127.0.0.1",
                  port: TestTcpServer.port(stalled_server),
                  connect_timeout: 1_000,
                  tls_options: [verify: :verify_none]}
               )

             send(test_process, {:slow_open_result, result})
           end},
          id: {:slow_open_task, self()}
        )
      )

    assert_receive {:wirekeeper_test_server, :accepted, ^stalled_server, 1}, 1_000

    _info_task =
      start_supervised!(
        Supervisor.child_spec(
          {Task,
           fn ->
             send(test_process, {:responsive_info_result, Wirekeeper.info(key)})
           end},
          id: {:responsive_info_task, self()}
        )
      )

    assert_receive {:responsive_info_result, {:ok, %{generation: generation}}}, 250
    assert generation == opened.generation
    assert_receive {:slow_open_result, {:error, {:transport, _reason}}}, 2_000
  end

  test "fast-closing peers cannot crash the manager or unrelated connections" do
    healthy_server = start_supervised!({TestTcpServer, self()})
    closing_server = start_supervised!({ClosingTcpServer, self()})
    healthy_key = unique_key("healthy-during-fast-close")

    assert {:ok, healthy} = open_tcp(healthy_key, healthy_server)
    on_exit(fn -> Wirekeeper.close(healthy_key, healthy.generation) end)
    assert_receive {:wirekeeper_test_server, :accepted, ^healthy_server, 1}
    manager = Process.whereis(Manager)
    supervisor = Process.whereis(TopicsClub.Wirekeeper.Supervisor)

    Enum.each(1..4, fn attempt ->
      key = unique_key("fast-close")

      result =
        Wirekeeper.open(
          key,
          {:tcp, host: "127.0.0.1", port: ClosingTcpServer.port(closing_server)},
          closed_retention_ms: 5_000
        )

      assert_receive {:wirekeeper_closing_server, :accepted, ^closing_server, ^attempt}

      case result do
        {:ok, opened} -> assert :ok = Wirekeeper.close(key, opened.generation)
        {:error, _reason} -> :ok
      end
    end)

    assert Process.whereis(Manager) == manager
    assert Process.whereis(TopicsClub.Wirekeeper.Supervisor) == supervisor
    assert {:ok, %{generation: generation}} = Wirekeeper.info(healthy_key)
    assert generation == healthy.generation
    assert TestTcpServer.connection_count(healthy_server) == 1
  end

  test "repeated manager crashes stay inside the manager restart boundary" do
    server = start_supervised!({TestTcpServer, self()})
    key = unique_key("manager-intensity")

    assert {:ok, opened} = open_tcp(key, server)
    on_exit(fn -> Wirekeeper.close(key, opened.generation) end)
    assert_receive {:wirekeeper_test_server, :accepted, ^server, 1}
    assert {:ok, connection} = Manager.lookup(key)
    supervisor = Process.whereis(TopicsClub.Wirekeeper.Supervisor)

    _last_manager =
      Enum.reduce(1..5, Process.whereis(Manager), fn _attempt, manager ->
        manager_ref = Process.monitor(manager)
        Process.exit(manager, :kill)
        assert_receive {:DOWN, ^manager_ref, :process, ^manager, :killed}
        replacement = await_named_process(Manager, manager)
        _ = :sys.get_state(replacement)
        replacement
      end)

    assert Process.whereis(TopicsClub.Wirekeeper.Supervisor) == supervisor
    assert {:ok, ^connection} = Manager.lookup(key)
    assert TestTcpServer.connection_count(server) == 1
  end

  test "lists and diagnoses both open connections and retained closed tombstones" do
    open_server = start_supervised!({TestTcpServer, self()})

    closed_server =
      start_supervised!(
        Supervisor.child_spec({TestTcpServer, self()}, id: {:closed_list_server, self()})
      )

    open_key = unique_key("listed-open")
    closed_key = unique_key("listed-closed")
    assert {:ok, opened} = open_tcp(open_key, open_server)
    assert {:ok, closed} = open_tcp(closed_key, closed_server, closed_retention_ms: 5_000)
    on_exit(fn -> Wirekeeper.close(open_key, opened.generation) end)
    on_exit(fn -> Wirekeeper.close(closed_key, closed.generation) end)
    assert_receive {:wirekeeper_test_server, :accepted, ^open_server, 1}
    assert_receive {:wirekeeper_test_server, :accepted, ^closed_server, 1}
    assert :ok = TestTcpServer.close_clients(closed_server)
    assert {:ok, %{status: :closed}} = await_connection_status(closed_key, :closed)

    assert {:ok, infos} = Wirekeeper.list()
    assert Enum.map(infos, &{&1.key, &1.status}) == [{closed_key, :closed}, {open_key, :open}]

    assert {:ok,
            %{
              total_connections: 2,
              open_connections: 1,
              closed_connections: 1,
              attached_connections: 0,
              detached_connections: 2
            }} = Wirekeeper.diagnostics()
  end

  test "list and diagnostics never omit a busy live connection from a successful snapshot" do
    server = start_supervised!({TestTcpServer, self()})
    key = unique_key("busy-list")

    assert {:ok, opened} = open_tcp(key, server)
    on_exit(fn -> Wirekeeper.close(key, opened.generation) end)
    assert_receive {:wirekeeper_test_server, :accepted, ^server, 1}
    assert {:ok, connection} = Manager.lookup(key)
    :ok = :sys.suspend(connection)

    on_exit(fn ->
      try do
        :sys.resume(connection)
      catch
        :exit, _reason -> :ok
      end
    end)

    assert {:error, :unavailable} = Wirekeeper.list()
    assert {:error, :unavailable} = Wirekeeper.diagnostics()
  end

  test "closes a connection when a non-reading peer exceeds the configured send timeout" do
    server = start_supervised!({NonReadingTcpServer, self()})
    key = unique_key("send-timeout")

    assert {:ok, opened} =
             Wirekeeper.open(
               key,
               {:tcp, host: "127.0.0.1", port: NonReadingTcpServer.port(server), send_timeout: 50}
             )

    on_exit(fn -> Wirekeeper.close(key, opened.generation) end)
    assert_receive {:wirekeeper_non_reading_server, :accepted, ^server}
    test_process = self()
    payload = :binary.copy(<<0>>, 1_048_576)

    _sender =
      start_supervised!(
        {Task,
         fn ->
           result =
             Enum.reduce_while(1..128, :ok, fn _attempt, :ok ->
               case Wirekeeper.send_data(key, opened.generation, payload) do
                 :ok -> {:cont, :ok}
                 error -> {:halt, error}
               end
             end)

           send(test_process, {:send_timeout_result, result})
         end}
      )

    assert_receive {:send_timeout_result, {:error, {:transport, :timeout}}}, 2_000

    assert {:ok, %{status: :closed, upstream_closed_reason: {:transport_error, :timeout}}} =
             Wirekeeper.info(key)
  end

  test "honors a socket send timeout longer than the default GenServer call timeout" do
    server = start_supervised!({NonReadingTcpServer, self()})
    key = unique_key("extended-send-timeout")

    assert {:ok, opened} =
             Wirekeeper.open(
               key,
               {:tcp,
                host: "127.0.0.1", port: NonReadingTcpServer.port(server), send_timeout: 5_250}
             )

    on_exit(fn -> Wirekeeper.close(key, opened.generation) end)
    assert_receive {:wirekeeper_non_reading_server, :accepted, ^server}
    test_process = self()
    payload = :binary.copy(<<0>>, 1_048_576)

    _sender =
      start_supervised!(
        {Task,
         fn ->
           result =
             Enum.reduce_while(1..128, :ok, fn _attempt, :ok ->
               case Wirekeeper.send_data(key, opened.generation, payload) do
                 :ok -> {:cont, :ok}
                 error -> {:halt, error}
               end
             end)

           send(test_process, {:extended_send_timeout_result, result})
         end}
      )

    assert_receive {:extended_send_timeout_result, {:error, {:transport, :timeout}}}, 7_000

    assert {:ok, %{status: :closed, upstream_closed_reason: {:transport_error, :timeout}}} =
             Wirekeeper.info(key)
  end

  test "reports upstream closure to the attached consumer and removes the connection" do
    server = start_supervised!({TestTcpServer, self()})
    key = unique_key("closed")

    assert {:ok, opened} = open_tcp(key, server)
    assert_receive {:wirekeeper_test_server, :accepted, ^server, 1}
    assert {:ok, _gap} = Wirekeeper.attach(key, opened.generation, self())

    assert :ok = TestTcpServer.close_clients(server)

    assert_receive {:topics_club_wirekeeper,
                    {:upstream_closed, %{key: ^key, generation: generation, reason: :closed}}}

    assert generation == opened.generation
    assert {:error, :not_found} = await_missing_connection(key)
  end

  defp open_tcp(key, server, opts \\ []) do
    Wirekeeper.open(
      key,
      {:tcp, host: "127.0.0.1", port: TestTcpServer.port(server)},
      opts
    )
  end

  defp unique_key(prefix) do
    "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
  end

  defp assert_server_data(server, expected, buffered \\ "") do
    receive do
      {:wirekeeper_test_server, :data, ^server, data} ->
        combined = buffered <> data

        unless String.contains?(combined, expected) do
          assert_server_data(server, expected, combined)
        end
    after
      1_000 -> flunk("TCP server did not receive #{inspect(expected)}")
    end
  end

  defp await_named_process(name, previous, attempts \\ 1_000)

  defp await_named_process(name, previous, attempts) when attempts > 0 do
    case Process.whereis(name) do
      replacement when is_pid(replacement) and replacement != previous ->
        replacement

      _missing_or_unchanged ->
        receive do
        after
          1 -> await_named_process(name, previous, attempts - 1)
        end
    end
  end

  defp await_named_process(name, _previous, 0) do
    flunk("#{inspect(name)} did not restart")
  end

  defp await_missing_connection(key, attempts \\ 1_000)

  defp await_missing_connection(key, attempts) when attempts > 0 do
    case Wirekeeper.info(key) do
      {:error, :not_found} = missing ->
        missing

      _still_present ->
        receive do
        after
          1 -> await_missing_connection(key, attempts - 1)
        end
    end
  end

  defp await_missing_connection(key, 0) do
    flunk("#{inspect(key)} remained registered after its upstream closed")
  end

  defp await_detached_connection(key, attempts \\ 1_000)

  defp await_detached_connection(key, attempts) when attempts > 0 do
    case Wirekeeper.info(key) do
      {:ok, %{attached?: false}} = detached ->
        detached

      _still_attached ->
        receive do
        after
          1 -> await_detached_connection(key, attempts - 1)
        end
    end
  end

  defp await_detached_connection(key, 0) do
    flunk("#{inspect(key)} did not detach its stopped consumer")
  end

  defp await_buffered_records(key, expected, attempts \\ 1_000)

  defp await_buffered_records(key, expected, attempts) when attempts > 0 do
    case Wirekeeper.info(key) do
      {:ok, %{buffered_records: ^expected}} = info ->
        info

      _not_buffered_yet ->
        receive do
        after
          1 -> await_buffered_records(key, expected, attempts - 1)
        end
    end
  end

  defp await_buffered_records(key, expected, 0) do
    flunk("#{inspect(key)} did not buffer #{expected} records")
  end

  defp await_dropped_records(key, expected, attempts \\ 1_000)

  defp await_dropped_records(key, expected, attempts) when attempts > 0 do
    case Wirekeeper.info(key) do
      {:ok, %{dropped_records: ^expected}} = info ->
        info

      _not_dropped_yet ->
        receive do
        after
          1 -> await_dropped_records(key, expected, attempts - 1)
        end
    end
  end

  defp await_dropped_records(key, expected, 0) do
    flunk("#{inspect(key)} did not report #{expected} dropped records")
  end

  defp await_adapter_buffer(connection, expected, attempts \\ 1_000)

  defp await_adapter_buffer(connection, expected, attempts) when attempts > 0 do
    case :sys.get_state(connection) do
      %{adapter_state: %{buffer: ^expected}} ->
        :ok

      _state ->
        receive do
        after
          1 -> await_adapter_buffer(connection, expected, attempts - 1)
        end
    end
  end

  defp await_adapter_buffer(connection, expected, 0) do
    flunk("#{inspect(connection)} did not retain IRC fragment #{inspect(expected)}")
  end

  defp await_connection_status(key, expected, attempts \\ 1_000)

  defp await_connection_status(key, expected, attempts) when attempts > 0 do
    case Wirekeeper.info(key) do
      {:ok, %{status: ^expected}} = info ->
        info

      _other ->
        receive do
        after
          1 -> await_connection_status(key, expected, attempts - 1)
        end
    end
  end

  defp await_connection_status(key, expected, 0) do
    flunk("#{inspect(key)} did not reach #{inspect(expected)}")
  end
end
