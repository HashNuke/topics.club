defmodule Ircpipe.IrcTestServer do
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
      test_pid: test_pid,
      port: port,
      labeled_responses?: Keyword.get(opts, :labeled_responses?, false),
      join_replies?: Keyword.get(opts, :join_replies?, true),
      motd_end?: Keyword.get(opts, :motd_end?, true),
      isupport_lines:
        Keyword.get(opts, :isupport_lines, [
          ":ircpipe-test 005 ircpipe CHANTYPES=# PREFIX=(ov)@+ :are supported"
        ])
    }

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
    {:noreply, %{state | socket: socket}}
  end

  def handle_info({:accepted, {:error, reason}}, state), do: {:stop, reason, state}

  def handle_info(:read, %{socket: socket, test_pid: test_pid} = state) do
    case :gen_tcp.recv(socket, 0, 100) do
      {:ok, line} ->
        line = String.trim(line)
        send(test_pid, {:irc_server_line, line})
        Enum.each(reply(line, state), &:gen_tcp.send(socket, [&1, "\r\n"]))

        if String.starts_with?(line, "PING ") do
          :ok = :gen_tcp.send(socket, "PONG :ircpipe-test\r\n")
        end

        send(self(), :read)
        {:noreply, state}

      {:error, :timeout} ->
        send(self(), :read)
        {:noreply, state}

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
    [":ircpipe-test CAP * LS :message-tags labeled-response batch"]
  end

  defp reply("CAP REQ :" <> capabilities, %{labeled_responses?: true}) do
    [":ircpipe-test CAP * ACK :#{capabilities}"]
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
          "@label=#{label} :ircpipe-test BATCH +whois-batch labeled-response",
          "@batch=whois-batch :ircpipe-test 311 ircpipe #{nick} user example.test * :Mira Example",
          "@batch=whois-batch :ircpipe-test NOTE WHOIS CACHED #{nick} :Result served from cache.",
          ":ircpipe-test BATCH -whois-batch"
        ]

      _command ->
        []
    end
  end

  defp reply("CAP LS" <> _rest, _state) do
    [":ircpipe-test CAP * LS :server-time echo-message multi-prefix userhost-in-names"]
  end

  defp reply("USER " <> _rest, state) do
    registration_lines(state)
  end

  defp reply("JOIN " <> _channel, %{join_replies?: false}), do: []

  defp reply("JOIN " <> channel, _state) do
    [
      ":ircpipe!user@test JOIN :#{channel}",
      ":ircpipe-test 353 ircpipe = #{channel} :@ircpipe akash +mira",
      ":ircpipe-test 366 ircpipe #{channel} :End of /NAMES list"
    ]
  end

  defp reply("PART " <> rest, _state) do
    [channel | reason] = String.split(rest, " ", parts: 2)
    suffix = if reason == [], do: "", else: " :#{List.first(reason)}"
    [":ircpipe!user@test PART #{channel}#{suffix}"]
  end

  defp reply("NICK " <> nick, _state) do
    [":ircpipe!user@test NICK :#{nick}"]
  end

  defp reply("LIST", _state) do
    [
      ":ircpipe-test 321 ircpipe Channel :Users Name",
      ":ircpipe-test 322 ircpipe #quiet 4 :A smaller conversation",
      ":ircpipe-test 322 ircpipe &local 3 :A local-only channel",
      ":ircpipe-test 322 ircpipe #elixir 42 :Elixir, OTP, and Phoenix",
      ":ircpipe-test 323 ircpipe :End of /LIST"
    ]
  end

  defp reply("WHOIS " <> nick, _state) do
    [
      ":ircpipe-test 311 ircpipe #{nick} user example.test * :Mira Example",
      ":ircpipe-test 312 ircpipe #{nick} ircpipe-test :Test server",
      ":ircpipe-test 318 ircpipe #{nick} :End of /WHOIS list"
    ]
  end

  defp reply(_line, _state), do: []

  defp registration_lines(state) do
    lines = [":ircpipe-test 001 ircpipe :Welcome to the test server" | state.isupport_lines]

    if state.motd_end? do
      lines ++ [":ircpipe-test 376 ircpipe :End of /MOTD command"]
    else
      lines
    end
  end
end
