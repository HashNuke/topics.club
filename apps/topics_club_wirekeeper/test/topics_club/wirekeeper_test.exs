defmodule TopicsClub.WirekeeperTest do
  use ExUnit.Case, async: false

  alias TopicsClub.Wirekeeper
  alias TopicsClub.Wirekeeper.Manager
  alias TopicsClub.Wirekeeper.ProtocolAdapter.IrcKeepalive
  alias TopicsClub.Wirekeeper.TestTcpServer

  test "keeps one TCP connection across detach and reattach while answering IRC PING" do
    server = start_supervised!({TestTcpServer, self()})
    key = unique_key("detach")

    assert {:ok, opened} = open_tcp(key, server, protocol_adapter: {IrcKeepalive, []})
    on_exit(fn -> Wirekeeper.close(key, opened.generation) end)

    assert_receive {:wirekeeper_test_server, :accepted, ^server, 1}
    assert {:ok, initial_gap} = Wirekeeper.attach(key, opened.generation, self())
    assert initial_gap.discarded_frames == 0

    inbound = ":irc.example NOTICE keeper :attached\r\n"
    assert :ok = TestTcpServer.send_data(server, inbound)

    assert_receive {:topics_club_wirekeeper,
                    {:data,
                     %{
                       key: ^key,
                       generation: opened_generation,
                       payload: ^inbound
                     }}}

    assert opened_generation == opened.generation

    outbound = "PRIVMSG #elixir :hello upstream\r\n"
    assert :ok = Wirekeeper.send_data(key, opened.generation, outbound)
    assert_server_data(server, outbound)

    assert :ok = Wirekeeper.detach(key, opened.generation, self())

    discarded = ":friend!u@h PRIVMSG #elixir :during restart\r\n"
    ping = "@label=keepalive :irc.example PING :token-42\r\n"
    assert :ok = TestTcpServer.send_data(server, discarded <> ping)
    assert_server_data(server, "PONG :token-42\r\n")
    refute_receive {:topics_club_wirekeeper, {:data, _event}}, 50

    assert {:ok, gap} = Wirekeeper.attach(key, opened.generation, self())
    assert gap.gap?
    assert gap.discarded_frames == 1
    assert gap.discarded_bytes == byte_size(discarded)
    assert gap.detached_for_ms >= 0
    assert TestTcpServer.connection_count(server) == 1
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

    discarded = "traffic after consumer crash\r\n"
    assert :ok = TestTcpServer.send_data(server, discarded)
    assert {:ok, %{discarded_frames: 1}} = await_discarded_frame(key)
    assert {:ok, gap} = Wirekeeper.attach(key, opened.generation, self())
    assert gap.gap?
    assert gap.discarded_frames == 1
    assert gap.discarded_bytes == byte_size(discarded)
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

  defp await_discarded_frame(key, attempts \\ 1_000)

  defp await_discarded_frame(key, attempts) when attempts > 0 do
    case Wirekeeper.info(key) do
      {:ok, %{discarded_frames: frames}} = info when frames > 0 ->
        info

      _not_discarded_yet ->
        receive do
        after
          1 -> await_discarded_frame(key, attempts - 1)
        end
    end
  end

  defp await_discarded_frame(key, 0) do
    flunk("#{inspect(key)} did not account for detached traffic")
  end
end
