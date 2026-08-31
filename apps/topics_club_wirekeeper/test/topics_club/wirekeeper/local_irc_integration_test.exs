if System.get_env("TOPICS_CLUB_LOCAL_IRC_INTEGRATION") == "1" do
  defmodule TopicsClub.Wirekeeper.LocalIrcIntegrationTest do
    use ExUnit.Case, async: false

    alias TopicsClub.Wirekeeper
    alias TopicsClub.Wirekeeper.ProtocolAdapter.IrcKeepalive

    @host "127.0.0.1"
    @port 6669

    test "keeps a real InspIRCd connection joined across detach and reattach" do
      unique = System.unique_integer([:positive, :monotonic]) |> rem(100_000)
      key = "local-irc-#{unique}"
      nick = "keeper#{unique}"
      observer_nick = "observe#{unique}"
      channel = "#keeper-#{unique}"

      assert {:ok, opened} =
               Wirekeeper.open(
                 key,
                 {:tcp, host: @host, port: @port},
                 protocol_adapter: {IrcKeepalive, []}
               )

      on_exit(fn -> Wirekeeper.close(key, opened.generation) end)
      assert {:ok, _gap} = Wirekeeper.attach(key, opened.generation, self())
      assert :ok = Wirekeeper.send_data(key, opened.generation, "NICK #{nick}\r\n")

      assert :ok =
               Wirekeeper.send_data(
                 key,
                 opened.generation,
                 "USER #{nick} 0 * :#{nick}\r\n"
               )

      assert_receive_line(&String.contains?(&1, " 001 #{nick} "), 15_000)
      assert :ok = Wirekeeper.send_data(key, opened.generation, "JOIN #{channel}\r\n")

      assert_receive_line(
        &String.contains?(&1, " 366 #{nick} #{channel} "),
        5_000
      )

      assert :ok = Wirekeeper.detach(key, opened.generation, self())
      assert {:ok, observer} = connect_observer(observer_nick)
      on_exit(fn -> :gen_tcp.close(observer) end)

      assert :ok = send_line(observer, "JOIN #{channel}")

      assert :ok =
               recv_until(
                 observer,
                 &String.contains?(&1, " 366 #{observer_nick} #{channel} "),
                 5_000
               )

      assert :ok = send_line(observer, "PRIVMSG #{channel} :discarded while detached")
      assert {:ok, discarded_info} = await_discarded_frame(key)
      assert discarded_info.generation == opened.generation

      assert {:ok, gap} = Wirekeeper.attach(key, opened.generation, self())
      assert gap.gap?
      assert gap.discarded_frames > 0
      assert gap.discarded_bytes > 0

      assert :ok = send_line(observer, "PRIVMSG #{channel} :delivered after reattach")

      assert_receive_line(
        &String.contains?(&1, "PRIVMSG #{channel} :delivered after reattach"),
        5_000
      )

      assert {:ok, %{attached?: true, generation: generation}} = Wirekeeper.info(key)
      assert generation == opened.generation
    end

    defp connect_observer(nick) do
      with {:ok, socket} <-
             :gen_tcp.connect(
               String.to_charlist(@host),
               @port,
               [:binary, packet: :line, active: false],
               1_000
             ),
           :ok <- send_line(socket, "NICK #{nick}"),
           :ok <- send_line(socket, "USER #{nick} 0 * :#{nick}"),
           :ok <- recv_until(socket, &String.contains?(&1, " 001 #{nick} "), 15_000) do
        {:ok, socket}
      end
    end

    defp send_line(socket, line), do: :gen_tcp.send(socket, line <> "\r\n")

    defp recv_until(socket, predicate, timeout_ms) do
      deadline = System.monotonic_time(:millisecond) + timeout_ms
      recv_until_deadline(socket, predicate, deadline)
    end

    defp recv_until_deadline(socket, predicate, deadline) do
      remaining = max(deadline - System.monotonic_time(:millisecond), 0)

      case :gen_tcp.recv(socket, 0, remaining) do
        {:ok, line} ->
          if predicate.(line), do: :ok, else: recv_until_deadline(socket, predicate, deadline)

        {:error, reason} ->
          {:error, reason}
      end
    end

    defp await_discarded_frame(key, attempts \\ 5_000)

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
      flunk("#{inspect(key)} did not account for detached IRC traffic")
    end

    defp assert_receive_line(predicate, timeout_ms) do
      deadline = System.monotonic_time(:millisecond) + timeout_ms
      assert_receive_line_before(predicate, deadline)
    end

    defp assert_receive_line_before(predicate, deadline) do
      remaining = max(deadline - System.monotonic_time(:millisecond), 0)

      receive do
        {:topics_club_wirekeeper, {:data, %{payload: line}}} ->
          if predicate.(line), do: :ok, else: assert_receive_line_before(predicate, deadline)
      after
        remaining -> flunk("expected IRC line was not received")
      end
    end
  end
end
