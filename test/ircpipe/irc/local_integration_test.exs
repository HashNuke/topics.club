if System.get_env("IRCPIPE_LOCAL_IRC_INTEGRATION") == "1" do
  defmodule Ircpipe.Irc.LocalIntegrationTest do
    use Ircpipe.DataCase

    @host "127.0.0.1"
    @port 6667

    test "local InspIRCd relays messages between IRC clients and irssi is available" do
      assert System.find_executable("irssi")

      unique = System.unique_integer([:positive]) |> rem(100_000)
      channel = "#ircpipe-it-#{unique}"
      listener_nick = "listen#{unique}"
      speaker_nick = "speak#{unique}"

      {:ok, listener} = connect_second_client(listener_nick)
      {:ok, speaker} = connect_second_client(speaker_nick)

      :ok = send_line(listener, "JOIN #{channel}")

      :ok =
        recv_until(
          listener,
          &(String.contains?(&1, " 366 ") and String.contains?(&1, channel)),
          5_000
        )

      :ok = send_line(speaker, "JOIN #{channel}")

      :ok =
        recv_until(
          listener,
          &(String.contains?(&1, "#{speaker_nick}!") and String.contains?(&1, " JOIN ") and
              String.contains?(&1, channel)),
          5_000
        )

      :ok = send_line(speaker, "PRIVMSG #{channel} :hello from local integration")

      assert :ok =
               recv_until(
                 listener,
                 &(String.contains?(&1, "#{speaker_nick}!") and
                     String.contains?(&1, " PRIVMSG #{channel} :hello from local integration")),
                 5_000
               )

      send_line(speaker, "QUIT :done")
      send_line(listener, "QUIT :done")
      :gen_tcp.close(speaker)
      :gen_tcp.close(listener)
    end

    defp connect_second_client(nick) do
      with {:ok, socket} <-
             :gen_tcp.connect(
               String.to_charlist(@host),
               @port,
               [:binary, packet: :line, active: false],
               1_000
             ),
           :ok <- send_line(socket, "NICK #{nick}"),
           :ok <- send_line(socket, "USER irctest 0 * #{nick}"),
           :ok <- recv_until(socket, &String.contains?(&1, " 001 "), 15_000) do
        {:ok, socket}
      end
    end

    defp send_line(socket, line), do: :gen_tcp.send(socket, line <> "\r\n")

    defp recv_until(socket, predicate, timeout_ms) do
      deadline = System.monotonic_time(:millisecond) + timeout_ms
      recv_until_deadline(socket, predicate, deadline)
    end

    defp recv_until_deadline(socket, predicate, deadline) do
      if System.monotonic_time(:millisecond) > deadline do
        {:error, :timeout}
      else
        case :gen_tcp.recv(socket, 0, 250) do
          {:ok, "PING " <> token} ->
            send_line(socket, "PONG #{String.trim(token)}")
            recv_until_deadline(socket, predicate, deadline)

          {:ok, line} ->
            if predicate.(line), do: :ok, else: recv_until_deadline(socket, predicate, deadline)

          {:error, :timeout} ->
            recv_until_deadline(socket, predicate, deadline)

          {:error, reason} ->
            {:error, reason}
        end
      end
    end
  end
end
