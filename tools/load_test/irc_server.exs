defmodule TopicsClub.LoadTest.IrcServer do
  @moduledoc false

  @table :topics_club_load_test_irc
  @counter_keys [
    :accepted_total,
    :active,
    :registered,
    :disconnected_total,
    :lines_received,
    :bytes_in,
    :bytes_out,
    :messages_sent,
    :privmsgs_received,
    :send_errors
  ]

  def start do
    table = :ets.new(@table, [:named_table, :public, read_concurrency: true])
    Enum.each(@counter_keys, &:ets.insert(table, {&1, 0}))

    irc_port = env_integer!("IRC_PORT", 6667)
    control_port = env_integer!("CONTROL_PORT", 8080)

    {:ok, irc_listener} = listen(irc_port, 65_535)
    {:ok, control_listener} = listen(control_port, 128)

    spawn_link(fn -> accept_irc(irc_listener) end)
    spawn_link(fn -> accept_control(control_listener) end)

    IO.puts("Synthetic IRC server listening on #{irc_port}; control port #{control_port}")
    Process.sleep(:infinity)
  end

  defp listen(port, backlog) do
    :gen_tcp.listen(port, [
      :binary,
      packet: :line,
      active: false,
      reuseaddr: true,
      nodelay: true,
      backlog: backlog,
      ip: {0, 0, 0, 0}
    ])
  end

  defp accept_irc(listener) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        pid = spawn(fn -> await_socket() end)
        :ok = :gen_tcp.controlling_process(socket, pid)
        send(pid, {:socket, socket})
        accept_irc(listener)

      {:error, reason} ->
        raise "IRC accept failed: #{inspect(reason)}"
    end
  end

  defp await_socket do
    receive do
      {:socket, socket} -> client_loop(socket, %{nick: "load", registered?: false})
    end
  end

  defp client_loop(socket, client) do
    increment(:accepted_total)
    increment(:active)
    put_client(socket, client)

    receive_client(socket, client)
  end

  defp receive_client(socket, client) do
    case :gen_tcp.recv(socket, 0) do
      {:ok, line} ->
        increment(:lines_received)
        increment(:bytes_in, byte_size(line))
        client = handle_line(socket, String.trim(line), client)
        put_client(socket, client)
        receive_client(socket, client)

      {:error, _reason} ->
        delete_client(client)
    end
  end

  defp handle_line(_socket, "NICK " <> nick, client) do
    %{client | nick: String.trim_leading(nick, ":")}
  end

  defp handle_line(socket, "USER " <> _rest, %{registered?: false} = client) do
    nick = client.nick

    send_lines(socket, [
      ":load.test 001 #{nick} :Welcome to the TopicsClub synthetic IRC server",
      ":load.test 005 #{nick} CHANTYPES=# PREFIX=(ov)@+ CASEMAPPING=rfc1459 :are supported",
      ":load.test 376 #{nick} :End of /MOTD command"
    ])

    increment(:registered)
    %{client | registered?: true}
  end

  defp handle_line(socket, "CAP LS" <> _rest, client) do
    send_lines(socket, [":load.test CAP * LS :"])
    client
  end

  defp handle_line(socket, "CAP REQ :" <> capabilities, client) do
    send_lines(socket, [":load.test CAP * ACK :#{capabilities}"])
    client
  end

  defp handle_line(socket, "PING " <> token, client) do
    send_lines(socket, ["PONG #{token}"])
    client
  end

  defp handle_line(socket, "JOIN " <> channel, client) do
    channel = String.trim_leading(channel, ":")

    send_lines(socket, [
      ":#{client.nick}!load@load.test JOIN :#{channel}",
      ":load.test 353 #{client.nick} = #{channel} :@#{client.nick}",
      ":load.test 366 #{client.nick} #{channel} :End of /NAMES list"
    ])

    client
  end

  defp handle_line(socket, "PRIVMSG " <> rest, client) do
    increment(:privmsgs_received)

    case String.split(rest, " :", parts: 2) do
      [target, body] ->
        send_lines(socket, [":#{client.nick}!load@load.test PRIVMSG #{target} :#{body}"])

      _invalid ->
        :ok
    end

    client
  end

  defp handle_line(_socket, _line, client), do: client

  defp delete_client(client) do
    :ets.delete(@table, {:client, self()})
    increment(:active, -1)
    if client.registered?, do: increment(:registered, -1)
    increment(:disconnected_total)
  end

  defp put_client(socket, client) do
    :ets.insert(@table, {{:client, self()}, socket, client.nick, client.registered?})
  end

  defp accept_control(listener) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        spawn(fn -> control(socket) end)
        accept_control(listener)

      {:error, reason} ->
        raise "control accept failed: #{inspect(reason)}"
    end
  end

  defp control(socket) do
    response =
      case :gen_tcp.recv(socket, 0, 5_000) do
        {:ok, command} -> run_control(String.trim(command))
        {:error, reason} -> "error=#{inspect(reason)}"
      end

    :gen_tcp.send(socket, [response, "\n"])
    :gen_tcp.close(socket)
  end

  defp run_control("PING"), do: "PONG"

  defp run_control("STATS") do
    @counter_keys
    |> Enum.map_join(" ", fn key -> "#{key}=#{counter(key)}" end)
  end

  defp run_control("DROP") do
    clients = clients()
    Enum.each(clients, fn {_socket, _nick} = client -> close_client(client) end)
    "dropped=#{length(clients)}"
  end

  defp run_control("BURST " <> count_text) do
    case Integer.parse(count_text) do
      {count, ""} when count in 1..100 -> burst(count, 65_535, 0)
      _invalid -> "error=invalid_burst_count"
    end
  end

  defp run_control("BURST_PACED " <> arguments) do
    with [count_text, batch_text, pause_text] <- String.split(arguments),
         {count, ""} when count in 1..100 <- Integer.parse(count_text),
         {batch, ""} when batch in 1..10_000 <- Integer.parse(batch_text),
         {pause_ms, ""} when pause_ms in 0..1_000 <- Integer.parse(pause_text) do
      burst(count, batch, pause_ms)
    else
      _invalid -> "error=invalid_paced_burst"
    end
  end

  defp run_control("PRIVMSG " <> arguments) do
    case String.split(arguments, " ", parts: 2) do
      ["#" <> _rest = target, body] when body != "" -> broadcast_message(target, body)
      _invalid -> "error=invalid_privmsg"
    end
  end

  defp run_control("NOTICE_ALL " <> body) when body != "", do: broadcast_notice(body)

  defp run_control(_command), do: "error=unknown_command"

  defp broadcast_message(target, body) do
    clients = clients()

    {sent, errors} =
      clients
      |> Task.async_stream(
        fn {socket, _nick} ->
          line = ":acceptance!user@load.test PRIVMSG #{target} :#{body}\r\n"

          case :gen_tcp.send(socket, line) do
            :ok ->
              increment(:bytes_out, byte_size(line))
              :sent

            {:error, _reason} ->
              :error
          end
        end,
        max_concurrency: min(max(length(clients), 1), 100),
        ordered: false,
        timeout: :infinity
      )
      |> Enum.reduce({0, 0}, fn
        {:ok, :sent}, {sent, errors} -> {sent + 1, errors}
        _error, {sent, errors} -> {sent, errors + 1}
      end)

    increment(:messages_sent, sent)
    increment(:send_errors, errors)
    "sent=#{sent} errors=#{errors}"
  end

  defp broadcast_notice(body) do
    clients = clients()

    {sent, errors} =
      clients
      |> Task.async_stream(
        fn {socket, nick} ->
          line = ":load.test NOTICE #{nick} :#{body}\r\n"

          case :gen_tcp.send(socket, line) do
            :ok ->
              increment(:bytes_out, byte_size(line))
              :sent

            {:error, _reason} ->
              :error
          end
        end,
        max_concurrency: min(max(length(clients), 1), 100),
        ordered: false,
        timeout: :infinity
      )
      |> Enum.reduce({0, 0}, fn
        {:ok, :sent}, {sent, errors} -> {sent + 1, errors}
        _error, {sent, errors} -> {sent, errors + 1}
      end)

    increment(:messages_sent, sent)
    increment(:send_errors, errors)
    "sent=#{sent} errors=#{errors}"
  end

  defp burst(per_connection, batch_size, pause_ms) do
    clients = clients()
    started = System.monotonic_time()

    {sent, errors} =
      clients
      |> Enum.chunk_every(batch_size)
      |> Enum.reduce({0, 0}, fn
        batch, totals ->
          totals = send_batch(batch, per_connection, totals)
          if pause_ms > 0, do: Process.sleep(pause_ms)
          totals
      end)

    increment(:messages_sent, sent)
    increment(:send_errors, errors)

    elapsed_ms =
      (System.monotonic_time() - started)
      |> System.convert_time_unit(:native, :millisecond)

    "sent=#{sent} errors=#{errors} elapsed_ms=#{elapsed_ms}"
  end

  defp send_batch(clients, per_connection, totals) do
    clients
    |> Task.async_stream(
      fn {socket, nick} -> send_burst(socket, nick, per_connection) end,
      max_concurrency: max(length(clients), 1),
      ordered: false,
      timeout: :infinity
    )
    |> Enum.reduce(totals, fn
      {:ok, {:ok, count}}, {sent, errors} -> {sent + count, errors}
      _error, {sent, errors} -> {sent, errors + 1}
    end)
  end

  defp send_burst(socket, nick, count) do
    result =
      Enum.reduce_while(1..count, 0, fn sequence, sent ->
        line = ":load.test NOTICE #{nick} :synthetic-load-message-#{sequence}\r\n"

        case :gen_tcp.send(socket, line) do
          :ok ->
            increment(:bytes_out, byte_size(line))
            {:cont, sent + 1}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)

    case result do
      sent when is_integer(sent) -> {:ok, sent}
      error -> error
    end
  end

  defp close_client({socket, _nick}), do: :gen_tcp.close(socket)

  defp clients do
    :ets.select(@table, [
      {{{:client, :_}, :"$1", :"$2", true}, [], [{{:"$1", :"$2"}}]}
    ])
  end

  defp send_lines(socket, lines) do
    payload = Enum.map(lines, &[&1, "\r\n"])

    case :gen_tcp.send(socket, payload) do
      :ok -> increment(:bytes_out, IO.iodata_length(payload))
      {:error, _reason} -> increment(:send_errors)
    end
  end

  defp increment(key, amount \\ 1), do: :ets.update_counter(@table, key, {2, amount})

  defp counter(key) do
    case :ets.lookup(@table, key) do
      [{^key, value}] -> value
      [] -> 0
    end
  end

  defp env_integer!(name, default) do
    System.get_env(name, Integer.to_string(default))
    |> Integer.parse()
    |> case do
      {value, ""} when value in 1..65_535 -> value
      _invalid -> raise "#{name} must be a valid TCP port"
    end
  end
end

TopicsClub.LoadTest.IrcServer.start()
