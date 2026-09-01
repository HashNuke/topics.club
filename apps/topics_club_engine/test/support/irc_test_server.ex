defmodule TopicsClub.IrcTestServer do
  use GenServer

  def start_link({test_pid, opts}) when is_list(opts) do
    GenServer.start_link(__MODULE__, {test_pid, opts})
  end

  def start_link(test_pid) when is_pid(test_pid) do
    GenServer.start_link(__MODULE__, test_pid)
  end

  def port(pid), do: GenServer.call(pid, :port)

  def broadcast(pid, channel, nick, body),
    do: GenServer.call(pid, {:broadcast, channel, nick, body})

  def send_line(pid, line), do: GenServer.call(pid, {:send_line, line})

  @impl true
  def init({test_pid, opts}) when is_list(opts) do
    start_listener(test_pid, opts)
  end

  def init(test_pid) do
    start_listener(test_pid, [])
  end

  defp start_listener(test_pid, opts) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, packet: :line, active: false, reuseaddr: true])
    {:ok, {_address, port}} = :inet.sockname(listener)

    state = %{
      listener: listener,
      socket: nil,
      connection_started?: false,
      test_pid: test_pid,
      port: port,
      labeled_responses?: Keyword.get(opts, :labeled_responses?, false),
      join_replies?: Keyword.get(opts, :join_replies?, true),
      part_replies?: Keyword.get(opts, :part_replies?, true),
      accept_reconnects?: Keyword.get(opts, :accept_reconnects?, false),
      motd_end?: Keyword.get(opts, :motd_end?, true),
      isupport_lines:
        Keyword.get(opts, :isupport_lines, [
          ":topics_club-test 005 topics_club CHANTYPES=# PREFIX=(ov)@+ :are supported"
        ])
    }

    accept_next(listener)

    {:ok, state}
  end

  @impl true
  def handle_call(:port, _from, state), do: {:reply, state.port, state}

  def handle_call({:broadcast, channel, nick, body}, _from, %{socket: socket} = state)
      when not is_nil(socket) do
    :ok = :gen_tcp.send(socket, ":#{nick}!user@test PRIVMSG #{channel} :#{body}\r\n")
    {:reply, :ok, state}
  end

  def handle_call({:broadcast, _channel, _nick, _body}, _from, state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call({:send_line, line}, _from, %{socket: socket} = state)
      when not is_nil(socket) do
    :ok = :gen_tcp.send(socket, [line, "\r\n"])
    {:reply, :ok, state}
  end

  def handle_call({:send_line, _line}, _from, state) do
    {:reply, {:error, :not_connected}, state}
  end

  @impl true
  def handle_info({:accepted, {:ok, socket}}, state) do
    send(self(), :read)
    {:noreply, %{state | socket: socket, connection_started?: false}}
  end

  def handle_info({:accepted, {:error, reason}}, state), do: {:stop, reason, state}

  def handle_info(:read, %{socket: socket, test_pid: test_pid} = state) do
    case :gen_tcp.recv(socket, 0, 100) do
      {:ok, line} ->
        line = String.trim(line)

        if not state.connection_started? and http_request_line?(line) do
          :ok = :gen_tcp.close(socket)
          accept_next(state.listener)
          {:noreply, %{state | socket: nil, connection_started?: false}}
        else
          send(test_pid, {:irc_server_line, line})
          Enum.each(reply(line, state), &:gen_tcp.send(socket, [&1, "\r\n"]))

          if String.starts_with?(line, "PING ") do
            :ok = :gen_tcp.send(socket, "PONG :topics_club-test\r\n")
          end

          send(self(), :read)
          {:noreply, %{state | connection_started?: true}}
        end

      {:error, :timeout} ->
        send(self(), :read)
        {:noreply, state}

      {:error, _reason} when state.accept_reconnects? ->
        accept_next(state.listener)
        {:noreply, %{state | socket: nil, connection_started?: false}}

      {:error, _reason} ->
        {:stop, :normal, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    if state.socket, do: :gen_tcp.close(state.socket)
    :gen_tcp.close(state.listener)
    :ok
  end

  defp reply("CAP LS" <> _rest, %{labeled_responses?: true}) do
    [":topics_club-test CAP * LS :message-tags labeled-response batch"]
  end

  defp reply("CAP REQ :" <> capabilities, %{labeled_responses?: true}) do
    [":topics_club-test CAP * ACK :#{capabilities}"]
  end

  defp reply("USER " <> _rest, %{labeled_responses?: true}), do: []

  defp reply("CAP END", %{labeled_responses?: true} = state) do
    registration_lines(state)
  end

  defp reply("@label=" <> tagged_command, %{labeled_responses?: true}) do
    [label, command] = String.split(tagged_command, " ", parts: 2)

    case command do
      "WHOIS " <> nick ->
        [
          "@label=#{label} :topics_club-test BATCH +whois-batch labeled-response",
          "@batch=whois-batch :topics_club-test 311 topics_club #{nick} user example.test * :Mira Example",
          "@batch=whois-batch :topics_club-test NOTE WHOIS CACHED #{nick} :Result served from cache.",
          ":topics_club-test BATCH -whois-batch"
        ]

      _command ->
        []
    end
  end

  defp reply("CAP LS" <> _rest, _state) do
    [":topics_club-test CAP * LS :server-time echo-message multi-prefix userhost-in-names"]
  end

  defp reply("USER " <> _rest, state) do
    registration_lines(state)
  end

  defp reply("JOIN " <> _channel, %{join_replies?: false}), do: []

  defp reply("JOIN " <> channel, _state) do
    [
      ":topics_club!user@test JOIN :#{channel}",
      ":topics_club-test 353 topics_club = #{channel} :@topics_club akash +mira",
      ":topics_club-test 366 topics_club #{channel} :End of /NAMES list"
    ]
  end

  defp reply("NAMES " <> channel, _state) do
    [
      ":topics_club-test 353 topics_club = #{channel} :@topics_club akash +mira",
      ":topics_club-test 366 topics_club #{channel} :End of /NAMES list"
    ]
  end

  defp reply("PART " <> _rest, %{part_replies?: false}), do: []

  defp reply("PART " <> rest, _state) do
    [channel | reason] = String.split(rest, " ", parts: 2)
    suffix = if reason == [], do: "", else: " :#{List.first(reason)}"
    [":topics_club!user@test PART #{channel}#{suffix}"]
  end

  defp reply("NICK " <> nick, _state) do
    [":topics_club!user@test NICK :#{nick}"]
  end

  defp reply("LIST", _state) do
    [
      ":topics_club-test 321 topics_club Channel :Users Name",
      ":topics_club-test 322 topics_club #quiet 4 :A smaller conversation",
      ":topics_club-test 322 topics_club &local 3 :A local-only channel",
      ":topics_club-test 322 topics_club #elixir 42 :Elixir, OTP, and Phoenix",
      ":topics_club-test 323 topics_club :End of /LIST"
    ]
  end

  defp reply("WHOIS " <> nick, _state) do
    [
      ":topics_club-test 311 topics_club #{nick} user example.test * :Mira Example",
      ":topics_club-test 312 topics_club #{nick} topics_club-test :Test server",
      ":topics_club-test 318 topics_club #{nick} :End of /WHOIS list"
    ]
  end

  defp reply(_line, _state), do: []

  defp registration_lines(state) do
    lines = [
      ":topics_club-test 001 topics_club :Welcome to the test server" | state.isupport_lines
    ]

    if state.motd_end? do
      lines ++ [":topics_club-test 376 topics_club :End of /MOTD command"]
    else
      lines
    end
  end

  defp http_request_line?(line) do
    case String.split(line, " ", parts: 3) do
      [method, _target, "HTTP/" <> _version]
      when method in ~w(GET HEAD POST PUT PATCH DELETE OPTIONS CONNECT TRACE) ->
        true

      _other ->
        false
    end
  end

  defp accept_next(listener) do
    parent = self()

    Task.start_link(fn ->
      case :gen_tcp.accept(listener) do
        {:ok, socket} ->
          :ok = :gen_tcp.controlling_process(socket, parent)
          send(parent, {:accepted, {:ok, socket}})

        {:error, reason} ->
          send(parent, {:accepted, {:error, reason}})
      end
    end)
  end
end
