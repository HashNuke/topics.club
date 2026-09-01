defmodule TopicsClub.WirekeeperTest do
  use ExUnit.Case, async: false

  alias TopicsClub.Wirekeeper
  alias TopicsClub.Wirekeeper.BlockingProtocolAdapter
  alias TopicsClub.Wirekeeper.BlockingConsumerWatcher
  alias TopicsClub.Wirekeeper.ClosingTcpServer
  alias TopicsClub.Wirekeeper.Manager
  alias TopicsClub.Wirekeeper.NonReadingTcpServer
  alias TopicsClub.Wirekeeper.ProtocolAdapter.IrcKeepalive
  alias TopicsClub.Wirekeeper.RejectingDelivery
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

  test "rejects malformed outbound data without closing a healthy connection" do
    server = start_supervised!({TestTcpServer, self()})
    key = unique_key("invalid-outbound-data")

    assert {:ok, opened} = open_tcp(key, server)
    on_exit(fn -> Wirekeeper.close(key, opened.generation) end)
    assert_receive {:wirekeeper_test_server, :accepted, ^server, 1}

    assert {:error, :invalid_data} =
             Wirekeeper.send_data(key, opened.generation, :not_iodata)

    assert {:ok, %{status: :open, upstream_closed_reason: nil}} = Wirekeeper.info(key)
    assert :ok = Wirekeeper.send_data(key, opened.generation, ["still ", "connected"])
    assert_server_data(server, "still connected")
    assert TestTcpServer.connection_count(server) == 1
  end

  test "writes each idempotency key set once within one socket generation" do
    server = start_supervised!({TestTcpServer, self()})
    key = unique_key("send-once")

    assert {:ok, opened} = open_tcp(key, server)
    on_exit(fn -> Wirekeeper.close(key, opened.generation) end)
    assert_receive {:wirekeeper_test_server, :accepted, ^server, 1}

    first = "@label=join-1 JOIN #elixir\r\n"

    assert :ok =
             Wirekeeper.send_data_once(
               key,
               opened.generation,
               ["attempt-1"],
               first
             )

    assert_server_data(server, first)

    assert :ok =
             Wirekeeper.send_data_once(
               key,
               opened.generation,
               ["attempt-1"],
               "JOIN #elixir\r\n"
             )

    refute_receive {:wirekeeper_test_server, :data, ^server, _duplicate}, 100
  end

  test "bounds idempotency keys and rejects partially overlapping key sets" do
    server = start_supervised!({TestTcpServer, self()})
    key = unique_key("bounded-send-once")

    assert {:ok, opened} = open_tcp(key, server, sent_once_max_keys: 2)
    on_exit(fn -> Wirekeeper.close(key, opened.generation) end)
    assert_receive {:wirekeeper_test_server, :accepted, ^server, 1}

    assert :ok =
             Wirekeeper.send_data_once(
               key,
               opened.generation,
               ["attempt-1", "attempt-2"],
               "JOIN #one,#two\r\n"
             )

    assert_server_data(server, "JOIN #one,#two\r\n")

    assert {:error, :idempotency_conflict} =
             Wirekeeper.send_data_once(
               key,
               opened.generation,
               ["attempt-2", "attempt-3"],
               "JOIN #two,#three\r\n"
             )

    assert {:error, :idempotency_capacity} =
             Wirekeeper.send_data_once(
               key,
               opened.generation,
               ["attempt-3"],
               "JOIN #three\r\n"
             )

    refute_receive {:wirekeeper_test_server, :data, ^server, _rejected}, 100
  end

  test "detached duration starts when the upstream connection becomes ready" do
    server = start_supervised!({TestTcpServer, self()})
    key = unique_key("detached-after-ready")
    test_process = self()

    _caller =
      start_supervised!(
        Supervisor.child_spec(
          {Task,
           fn ->
             result =
               open_tcp(key, server,
                 protocol_adapter: {BlockingProtocolAdapter, owner: test_process}
               )

             send(test_process, {:delayed_ready_open_result, result})
           end},
          id: {:delayed_ready_open, self()}
        )
      )

    assert_receive {:wirekeeper_blocking_adapter, :init_started, connection}
    _timer = Process.send_after(self(), :release_delayed_adapter, 250)
    assert_receive :release_delayed_adapter, 500
    send(connection, :continue_wirekeeper_adapter_init)

    assert_receive {:delayed_ready_open_result, {:ok, opened}}
    assert_receive {:wirekeeper_test_server, :accepted, ^server, 1}
    assert {:ok, replay} = Wirekeeper.attach(key, opened.generation, self())
    assert replay.detached_for_ms < 100
    assert :ok = Wirekeeper.close(key, opened.generation)
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

  test "detaches a backpressured consumer and retains its record for replay" do
    server = start_supervised!({TestTcpServer, self()})
    key = unique_key("consumer-backpressure")

    assert {:ok, opened} = open_tcp(key, server)
    on_exit(fn -> Wirekeeper.close(key, opened.generation) end)
    assert_receive {:wirekeeper_test_server, :accepted, ^server, 1}
    assert {:ok, _replay} = Wirekeeper.attach(key, opened.generation, self())
    assert {:ok, connection} = Manager.lookup(key)

    :sys.replace_state(connection, fn state ->
      Map.put(state, :delivery, RejectingDelivery)
    end)

    payload = "retained while distribution is backpressured"
    assert :ok = TestTcpServer.send_data(server, payload)

    assert {:ok, %{attached?: false, buffered_records: 1, in_flight_records: 0}} =
             await_detached_connection(key)

    refute_receive {:topics_club_wirekeeper, {:data, _event}}

    assert {:error, :consumer_unreachable} =
             Wirekeeper.attach(key, opened.generation, self())

    assert {:ok, %{attached?: false, buffered_records: 1, in_flight_records: 0}} =
             Wirekeeper.info(key)

    :sys.replace_state(connection, fn state ->
      Map.put(state, :delivery, TopicsClub.Wirekeeper.Delivery)
    end)

    assert {:ok, %{replayed_records: 1}} =
             Wirekeeper.attach(key, opened.generation, self())

    assert_receive {:topics_club_wirekeeper, {:data, %{sequence: sequence, payload: ^payload}}}

    assert :ok = Wirekeeper.ack(key, opened.generation, sequence)
  end

  test "keeps remote consumer monitoring outside the connection process" do
    server = start_supervised!({TestTcpServer, self()})
    key = unique_key("consumer-watcher")

    assert {:ok, opened} = open_tcp(key, server)
    on_exit(fn -> Wirekeeper.close(key, opened.generation) end)
    assert_receive {:wirekeeper_test_server, :accepted, ^server, 1}
    assert {:ok, connection} = Manager.lookup(key)
    test_process = self()

    :sys.replace_state(connection, fn state ->
      Map.put(
        state,
        :consumer_watcher_spec,
        {BlockingConsumerWatcher, owner: test_process}
      )
    end)

    assert {:ok, _replay} = Wirekeeper.attach(key, opened.generation, self())

    assert_receive {:wirekeeper_blocking_consumer_watcher, watcher, ^connection, ^test_process}

    watcher_ref = Process.monitor(watcher)
    _state = :sys.get_state(connection)
    payload = "socket handling remains live while the watcher is blocked"
    assert :ok = TestTcpServer.send_data(server, payload)

    assert_receive {:topics_club_wirekeeper, {:data, %{sequence: sequence, payload: ^payload}}}

    assert :ok = Wirekeeper.ack(key, opened.generation, sequence)
    assert :ok = Wirekeeper.detach(key, opened.generation, self())
    assert_receive {:DOWN, ^watcher_ref, :process, ^watcher, :killed}
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

  test "a stalled connection handshake does not serialize healthy connection opens" do
    stalled_server = start_supervised!({TestTcpServer, self()})

    healthy_server =
      start_supervised!(
        Supervisor.child_spec({TestTcpServer, self()}, id: {:healthy_parallel_server, self()})
      )

    test_process = self()

    _stalled_open =
      start_supervised!(
        Supervisor.child_spec(
          {Task,
           fn ->
             result =
               Wirekeeper.open(
                 unique_key("parallel-stalled-open"),
                 {:tls,
                  host: "127.0.0.1",
                  port: TestTcpServer.port(stalled_server),
                  connect_timeout: 1_000,
                  tls_options: [verify: :verify_none]}
               )

             send(test_process, {:parallel_stalled_result, result})
           end},
          id: {:parallel_stalled_open, self()}
        )
      )

    assert_receive {:wirekeeper_test_server, :accepted, ^stalled_server, 1}, 1_000
    healthy_key = unique_key("parallel-healthy-open")

    _healthy_open =
      start_supervised!(
        Supervisor.child_spec(
          {Task,
           fn ->
             result = open_tcp(healthy_key, healthy_server)
             send(test_process, {:parallel_healthy_result, result})
           end},
          id: {:parallel_healthy_open, self()}
        )
      )

    assert_receive {:wirekeeper_test_server, :accepted, ^healthy_server, 1}, 250
    assert_receive {:parallel_healthy_result, {:ok, healthy}}, 250
    assert :ok = Wirekeeper.close(healthy_key, healthy.generation)
    assert_receive {:parallel_stalled_result, {:error, {:transport, _reason}}}, 2_000
  end

  test "bounds pending opens while a connection handshake is stalled" do
    stalled_server = start_supervised!({TestTcpServer, self()})
    test_process = self()

    _first_open =
      start_supervised!(
        Supervisor.child_spec(
          {Task,
           fn ->
             result =
               Wirekeeper.open(
                 unique_key("first-stalled-open"),
                 {:tls,
                  host: "127.0.0.1",
                  port: TestTcpServer.port(stalled_server),
                  connect_timeout: 2_000,
                  tls_options: [verify: :verify_none]}
               )

             send(test_process, {:stalled_open_result, result})
           end},
          id: {:first_stalled_open, self()}
        )
      )

    assert_receive {:wirekeeper_test_server, :accepted, ^stalled_server, 1}, 1_000

    Enum.each(1..20, fn index ->
      start_supervised!(
        Supervisor.child_spec(
          {Task,
           fn ->
             result =
               Wirekeeper.open(
                 unique_key("queued-stalled-open-#{index}"),
                 {:tls,
                  host: "127.0.0.1",
                  port: TestTcpServer.port(stalled_server),
                  connect_timeout: 2_000,
                  tls_options: [verify: :verify_none]}
               )

             send(test_process, {:queued_open_result, result})
           end},
          id: {:queued_stalled_open, index, self()}
        )
      )
    end)

    assert_receive {:queued_open_result, {:error, :overloaded}}, 500
    manager_state = :sys.get_state(Manager)
    assert map_size(manager_state.opening_by_key) <= 8
    assert length(Task.Supervisor.children(TopicsClub.Wirekeeper.OpenTaskSupervisor)) <= 8
  end

  test "enforces a configured global connection limit before opening another socket" do
    previous_limit = Application.get_env(:topics_club_wirekeeper, :max_connections)
    Application.put_env(:topics_club_wirekeeper, :max_connections, 1)

    on_exit(fn ->
      if is_nil(previous_limit) do
        Application.delete_env(:topics_club_wirekeeper, :max_connections)
      else
        Application.put_env(:topics_club_wirekeeper, :max_connections, previous_limit)
      end
    end)

    server = start_supervised!({TestTcpServer, self()})
    first_key = unique_key("global-limit-first")
    second_key = unique_key("global-limit-second")

    assert {:ok, first} = open_tcp(first_key, server)
    on_exit(fn -> Wirekeeper.close(first_key, first.generation) end)
    assert_receive {:wirekeeper_test_server, :accepted, ^server, 1}

    second_result = open_tcp(second_key, server)

    case second_result do
      {:ok, second} -> on_exit(fn -> Wirekeeper.close(second_key, second.generation) end)
      {:error, _reason} -> :ok
    end

    assert second_result == {:error, :connection_limit}
    assert TestTcpServer.connection_count(server) == 1
  end

  test "cancels pending opens when their callers terminate" do
    stalled_server = start_supervised!({TestTcpServer, self()})
    test_process = self()

    callers =
      Enum.map(1..8, fn index ->
        key = unique_key("abandoned-stalled-open-#{index}")

        caller =
          start_supervised!(
            Supervisor.child_spec(
              {Task,
               fn ->
                 send(test_process, {:abandoned_open_started, self(), key})

                 Wirekeeper.open(
                   key,
                   {:tls,
                    host: "127.0.0.1",
                    port: TestTcpServer.port(stalled_server),
                    connect_timeout: 5_000,
                    tls_options: [verify: :verify_none]}
                 )
               end},
              id: {:abandoned_stalled_open, index, self()}
            )
          )

        assert_receive {:abandoned_open_started, ^caller, ^key}
        {caller, key}
      end)

    assert %{opening_by_key: opening_by_key} = await_pending_open_count(8)
    assert map_size(opening_by_key) == 8

    Enum.each(callers, fn {caller, _key} ->
      caller_ref = Process.monitor(caller)
      Process.exit(caller, :kill)
      assert_receive {:DOWN, ^caller_ref, :process, ^caller, :killed}
    end)

    assert %{opening_by_key: opening_by_key} = await_pending_open_count(0)
    assert opening_by_key == %{}
    assert Task.Supervisor.children(TopicsClub.Wirekeeper.OpenTaskSupervisor) == []

    Enum.each(callers, fn {_caller, key} ->
      assert {:error, :not_found} = await_missing_connection(key)
    end)

    healthy_server =
      start_supervised!(
        Supervisor.child_spec({TestTcpServer, self()}, id: {:healthy_after_abandon, self()})
      )

    healthy_key = unique_key("healthy-after-abandon")
    assert {:ok, opened} = open_tcp(healthy_key, healthy_server)
    assert_receive {:wirekeeper_test_server, :accepted, ^healthy_server, 1}, 250
    assert :ok = Wirekeeper.close(healthy_key, opened.generation)
  end

  test "caller cancellation cannot leave a connection whose child start was in progress" do
    server = start_supervised!({TestTcpServer, self()})
    key = unique_key("cancel-during-child-start")
    test_process = self()

    caller =
      start_supervised!(
        Supervisor.child_spec(
          {Task,
           fn ->
             send(test_process, {:cancel_race_caller, self()})

             open_tcp(key, server,
               protocol_adapter: {BlockingProtocolAdapter, owner: test_process}
             )
           end},
          id: {:cancel_during_child_start, self()}
        )
      )

    assert_receive {:cancel_race_caller, ^caller}
    assert_receive {:wirekeeper_blocking_adapter, :init_started, connection}
    connection_ref = Process.monitor(connection)
    caller_ref = Process.monitor(caller)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^caller_ref, :process, ^caller, :killed}
    assert await_pending_open_count(0).opening_by_key == %{}

    send(connection, :continue_wirekeeper_adapter_init)

    assert_receive {:DOWN, ^connection_ref, :process, ^connection, _reason}, 500
    assert {:error, :not_found} = await_missing_connection(key)
    refute_receive {:wirekeeper_test_server, :accepted, ^server, 1}, 100
  end

  test "caller cancellation also cancels a child start queued in the connection supervisor" do
    canceled_server = start_supervised!({TestTcpServer, self()})

    probe_server =
      start_supervised!(
        Supervisor.child_spec({TestTcpServer, self()}, id: {:queued_cancel_probe_server, self()})
      )

    connection_supervisor = Process.whereis(TopicsClub.Wirekeeper.ConnectionSupervisor)
    :ok = :sys.suspend(connection_supervisor)

    on_exit(fn ->
      try do
        :ok = :sys.resume(connection_supervisor)
      catch
        :exit, _reason -> :ok
      end
    end)

    canceled_key = unique_key("queued-canceled-open")

    caller =
      start_supervised!(
        Supervisor.child_spec(
          {Task, fn -> open_tcp(canceled_key, canceled_server) end},
          id: {:queued_canceled_open, self()}
        )
      )

    assert await_pending_open_count(1).opening_by_key != %{}
    caller_ref = Process.monitor(caller)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^caller_ref, :process, ^caller, :killed}
    assert await_pending_open_count(0).opening_by_key == %{}

    :ok = :sys.resume(connection_supervisor)
    probe_key = unique_key("queued-cancel-probe")
    assert {:ok, probe} = open_tcp(probe_key, probe_server)
    assert_receive {:wirekeeper_test_server, :accepted, ^probe_server, 1}
    assert :ok = Wirekeeper.close(probe_key, probe.generation)

    assert {:error, :not_found} = Wirekeeper.info(canceled_key)
    refute_receive {:wirekeeper_test_server, :accepted, ^canceled_server, 1}, 100
  end

  test "open task supervisor failure cannot orphan an in-progress connection" do
    server = start_supervised!({TestTcpServer, self()})
    key = unique_key("open-task-supervisor-failure")
    test_process = self()

    _caller =
      start_supervised!(
        Supervisor.child_spec(
          {Task,
           fn ->
             open_tcp(key, server,
               protocol_adapter: {BlockingProtocolAdapter, owner: test_process}
             )
           end},
          id: {:open_task_supervisor_failure_caller, self()}
        )
      )

    assert_receive {:wirekeeper_blocking_adapter, :init_started, connection}
    task_supervisor = Process.whereis(TopicsClub.Wirekeeper.OpenTaskSupervisor)
    manager = Process.whereis(Manager)
    connection_ref = Process.monitor(connection)
    task_supervisor_ref = Process.monitor(task_supervisor)
    manager_ref = Process.monitor(manager)

    Process.exit(task_supervisor, :kill)

    assert_receive {:DOWN, ^task_supervisor_ref, :process, ^task_supervisor, :killed}
    assert_receive {:DOWN, ^manager_ref, :process, ^manager, :shutdown}
    assert_receive {:DOWN, ^connection_ref, :process, ^connection, _reason}, 500

    _replacement_task_supervisor =
      await_named_process(TopicsClub.Wirekeeper.OpenTaskSupervisor, task_supervisor)

    _replacement_manager = await_named_process(Manager, manager)
    assert {:error, :not_found} = await_missing_connection(key)
    refute_receive {:wirekeeper_test_server, :accepted, ^server, 1}, 100
  end

  test "manager failure cancels its in-progress connection opens" do
    server = start_supervised!({TestTcpServer, self()})
    key = unique_key("manager-failure-during-open")
    test_process = self()

    _caller =
      start_supervised!(
        Supervisor.child_spec(
          {Task,
           fn ->
             result =
               open_tcp(key, server,
                 protocol_adapter: {BlockingProtocolAdapter, owner: test_process}
               )

             send(test_process, {:manager_failure_open_result, result})
           end},
          id: {:manager_failure_during_open, self()}
        )
      )

    assert_receive {:wirekeeper_blocking_adapter, :init_started, connection}
    connection_ref = Process.monitor(connection)
    manager = Process.whereis(Manager)
    manager_ref = Process.monitor(manager)
    Process.exit(manager, :kill)

    assert_receive {:DOWN, ^manager_ref, :process, ^manager, :killed}
    assert_receive {:manager_failure_open_result, {:error, :unavailable}}
    send(connection, :continue_wirekeeper_adapter_init)

    assert_receive {:DOWN, ^connection_ref, :process, ^connection, _reason}, 500
    _replacement_manager = await_named_process(Manager, manager)
    assert {:error, :not_found} = await_missing_connection(key)
    refute_receive {:wirekeeper_test_server, :accepted, ^server, 1}, 100
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

  test "malformed open options cannot restart the manager or drop healthy sockets" do
    server = start_supervised!({TestTcpServer, self()})
    healthy_key = unique_key("healthy-during-invalid-options")

    assert {:ok, opened} = open_tcp(healthy_key, server)
    on_exit(fn -> Wirekeeper.close(healthy_key, opened.generation) end)
    assert_receive {:wirekeeper_test_server, :accepted, ^server, 1}
    manager = Process.whereis(Manager)
    supervisor = Process.whereis(TopicsClub.Wirekeeper.Supervisor)
    transport = {:tcp, host: "127.0.0.1", port: TestTcpServer.port(server)}

    results =
      Enum.map(1..25, fn attempt ->
        Wirekeeper.open(unique_key("invalid-options-#{attempt}"), transport, %{})
      end)

    assert Enum.uniq(results) == [{:error, :invalid_options}]
    assert Process.whereis(Manager) == manager
    assert Process.whereis(TopicsClub.Wirekeeper.Supervisor) == supervisor
    assert {:ok, %{generation: generation}} = Wirekeeper.info(healthy_key)
    assert generation == opened.generation
    assert TestTcpServer.connection_count(server) == 1
  end

  test "failed opens release their key before the caller can retry" do
    server = start_supervised!({TestTcpServer, self()})
    transport = {:tcp, host: "127.0.0.1", port: TestTcpServer.port(server)}
    adapter = {TopicsClub.Wirekeeper.LowPriorityFailingAdapter, []}

    results =
      Enum.map(1..500, fn attempt ->
        key = unique_key("failed-open-retry-#{attempt}")
        first = Wirekeeper.open(key, transport, protocol_adapter: adapter)
        retry = Wirekeeper.open(key, transport, protocol_adapter: adapter)
        {first, retry}
      end)

    assert Enum.uniq(results) ==
             [
               {{:error, {:transport, :forced_failure}}, {:error, {:transport, :forced_failure}}}
             ]

    refute_receive {:wirekeeper_test_server, :accepted, ^server, _count}
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

  test "registry failure replaces every identity-dependent process without orphaning sockets" do
    server = start_supervised!({TestTcpServer, self()})
    key = unique_key("registry-lifecycle")

    assert {:ok, _opened} = open_tcp(key, server)
    assert_receive {:wirekeeper_test_server, :accepted, ^server, 1}
    assert {:ok, connection} = Manager.lookup(key)

    registry = Process.whereis(TopicsClub.Wirekeeper.ConnectionRegistry)
    connection_supervisor = Process.whereis(TopicsClub.Wirekeeper.ConnectionSupervisor)
    task_supervisor = Process.whereis(TopicsClub.Wirekeeper.OpenTaskSupervisor)
    manager = Process.whereis(Manager)

    registry_ref = Process.monitor(registry)
    connection_ref = Process.monitor(connection)
    connection_supervisor_ref = Process.monitor(connection_supervisor)
    task_supervisor_ref = Process.monitor(task_supervisor)
    manager_ref = Process.monitor(manager)

    Process.exit(registry, :kill)

    assert_receive {:DOWN, ^registry_ref, :process, ^registry, :killed}
    assert_receive {:DOWN, ^connection_ref, :process, ^connection, :shutdown}

    assert_receive {:DOWN, ^connection_supervisor_ref, :process, ^connection_supervisor,
                    :shutdown}

    assert_receive {:DOWN, ^task_supervisor_ref, :process, ^task_supervisor, :shutdown}
    assert_receive {:DOWN, ^manager_ref, :process, ^manager, _reason}
    assert_receive {:wirekeeper_test_server, :closed, ^server, 0}

    _replacement_registry =
      await_named_process(TopicsClub.Wirekeeper.ConnectionRegistry, registry)

    _replacement_connection_supervisor =
      await_named_process(TopicsClub.Wirekeeper.ConnectionSupervisor, connection_supervisor)

    _replacement_task_supervisor =
      await_named_process(TopicsClub.Wirekeeper.OpenTaskSupervisor, task_supervisor)

    _replacement_manager = await_named_process(Manager, manager)

    assert {:ok, replacement} = open_tcp(key, server)
    assert_receive {:wirekeeper_test_server, :accepted, ^server, 1}
    assert {:error, :already_open} = open_tcp(key, server)
    assert TestTcpServer.connection_count(server) == 1
    assert :ok = Wirekeeper.close(key, replacement.generation)
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
              transport_api_version: 1,
              features: [:send_once],
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

  test "list bounds concurrent snapshot workers independently of connection count" do
    server = start_supervised!({TestTcpServer, self()})

    connections =
      Enum.map(1..20, fn index ->
        key = unique_key("bounded-list-#{index}")
        assert {:ok, opened} = open_tcp(key, server)
        assert {:ok, connection} = Manager.lookup(key)
        {key, opened.generation, connection}
      end)

    Enum.each(connections, fn {_key, _generation, connection} ->
      :ok = :sys.suspend(connection)
    end)

    on_exit(fn ->
      Enum.each(connections, fn {key, generation, connection} ->
        try do
          :sys.resume(connection)
        catch
          :exit, _reason -> :ok
        end

        Wirekeeper.close(key, generation)
      end)
    end)

    :erlang.trace(:new_processes, true, [:procs, {:tracer, self()}])
    on_exit(fn -> :erlang.trace(:new_processes, false, [:procs]) end)
    test_process = self()

    list_task =
      start_supervised!(
        {Task, fn -> send(test_process, {:bounded_list_result, Wirekeeper.list()}) end}
      )

    assert_receive {:bounded_list_result, {:error, :unavailable}}, 1_000
    :erlang.trace(:new_processes, false, [:procs])
    trace_delivery = :erlang.trace_delivered(:all)
    assert_receive {:trace_delivered, :all, ^trace_delivery}
    trace_messages = collect_trace_messages([])
    coordinator = snapshot_coordinator(trace_messages, list_task)

    worker_count =
      Enum.count(trace_messages, fn
        {:trace, ^coordinator, :spawn, _worker, {Task.Supervised, :reply, _arguments}} -> true
        _message -> false
      end)

    assert worker_count <= 8
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

  defp await_pending_open_count(expected, attempts \\ 1_000)

  defp await_pending_open_count(expected, attempts) when attempts > 0 do
    state = :sys.get_state(Manager)

    if map_size(state.opening_by_key) == expected do
      state
    else
      receive do
      after
        1 -> await_pending_open_count(expected, attempts - 1)
      end
    end
  end

  defp await_pending_open_count(expected, 0) do
    state = :sys.get_state(Manager)

    flunk("expected #{expected} pending opens, found #{map_size(state.opening_by_key)}")
  end

  defp collect_trace_messages(messages) do
    receive do
      {:trace, _process, _event, _detail} = message ->
        collect_trace_messages([message | messages])

      {:trace, _process, _event, _detail, _extra} = message ->
        collect_trace_messages([message | messages])
    after
      0 -> Enum.reverse(messages)
    end
  end

  defp snapshot_coordinator(trace_messages, list_task) do
    Enum.find_value(trace_messages, fn
      {:trace, ^list_task, :spawn, coordinator, {:erlang, :apply, [function, []]}} ->
        case :erlang.fun_info(function, :module) do
          {:module, Task.Supervised} -> coordinator
          _other_module -> nil
        end

      _message ->
        nil
    end) || flunk("list did not start a snapshot coordinator")
  end
end
