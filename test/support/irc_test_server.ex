defmodule Ircpipe.IrcTestServer do
  use GenServer

  def start_link(test_pid) do
    GenServer.start_link(__MODULE__, test_pid)
  end

  def port(pid), do: GenServer.call(pid, :port)

  def broadcast(pid, channel, nick, body),
    do: GenServer.call(pid, {:broadcast, channel, nick, body})

  @impl true
  def init(test_pid) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, packet: :line, active: false, reuseaddr: true])
    {:ok, {_address, port}} = :inet.sockname(listener)
    state = %{listener: listener, socket: nil, test_pid: test_pid, port: port}
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
        Enum.each(reply(line), &:gen_tcp.send(socket, [&1, "\r\n"]))

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

  defp reply("CAP LS" <> _rest) do
    [":ircpipe-test CAP * LS :server-time echo-message multi-prefix userhost-in-names"]
  end

  defp reply("USER " <> _rest) do
    [
      ":ircpipe-test 001 ircpipe :Welcome to the test server",
      ":ircpipe-test 005 ircpipe CHANTYPES=# PREFIX=(ov)@+ :are supported"
    ]
  end

  defp reply("JOIN " <> channel) do
    [
      ":ircpipe!user@test JOIN :#{channel}",
      ":ircpipe-test 353 ircpipe = #{channel} :@ircpipe akash +mira",
      ":ircpipe-test 366 ircpipe #{channel} :End of /NAMES list"
    ]
  end

  defp reply("LIST") do
    [
      ":ircpipe-test 321 ircpipe Channel :Users Name",
      ":ircpipe-test 322 ircpipe #quiet 4 :A smaller conversation",
      ":ircpipe-test 322 ircpipe &local 3 :A local-only channel",
      ":ircpipe-test 322 ircpipe #elixir 42 :Elixir, OTP, and Phoenix",
      ":ircpipe-test 323 ircpipe :End of /LIST"
    ]
  end

  defp reply(_line), do: []
end
