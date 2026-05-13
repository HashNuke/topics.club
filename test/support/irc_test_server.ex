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
    send(self(), :accept)
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
  def handle_info(:accept, state) do
    {:ok, socket} = :gen_tcp.accept(state.listener)
    send(self(), :read)
    {:noreply, %{state | socket: socket}}
  end

  def handle_info(:read, %{socket: socket, test_pid: test_pid} = state) do
    case :gen_tcp.recv(socket, 0, 100) do
      {:ok, line} ->
        line = String.trim(line)
        send(test_pid, {:irc_server_line, line})

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
end
