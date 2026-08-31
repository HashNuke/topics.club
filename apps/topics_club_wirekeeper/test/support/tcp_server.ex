defmodule TopicsClub.Wirekeeper.TestTcpServer do
  @moduledoc false

  use GenServer

  def start_link(owner) do
    GenServer.start_link(__MODULE__, owner)
  end

  def port(server), do: GenServer.call(server, :port)
  def connection_count(server), do: GenServer.call(server, :connection_count)
  def send_data(server, data), do: GenServer.call(server, {:send_data, data})
  def close_clients(server), do: GenServer.call(server, :close_clients)

  @impl true
  def init(owner) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

    {:ok, {_address, port}} = :inet.sockname(listener)
    server = self()
    _acceptor = spawn_link(fn -> accept_loop(listener, server) end)

    {:ok, %{listener: listener, owner: owner, port: port, sockets: MapSet.new()}}
  end

  @impl true
  def handle_call(:port, _from, state), do: {:reply, state.port, state}

  def handle_call(:connection_count, _from, state) do
    {:reply, MapSet.size(state.sockets), state}
  end

  def handle_call({:send_data, data}, _from, state) do
    result = Enum.reduce_while(state.sockets, :ok, &send_to_socket(&1, data, &2))
    {:reply, result, state}
  end

  def handle_call(:close_clients, _from, state) do
    Enum.each(state.sockets, &:gen_tcp.close/1)
    {:reply, :ok, %{state | sockets: MapSet.new()}}
  end

  @impl true
  def handle_info({:accepted, socket}, state) do
    :ok = :inet.setopts(socket, active: :once)
    sockets = MapSet.put(state.sockets, socket)
    send(state.owner, {:wirekeeper_test_server, :accepted, self(), MapSet.size(sockets)})
    {:noreply, %{state | sockets: sockets}}
  end

  def handle_info({:tcp, socket, data}, state) do
    send(state.owner, {:wirekeeper_test_server, :data, self(), data})
    :ok = :inet.setopts(socket, active: :once)
    {:noreply, state}
  end

  def handle_info({:tcp_closed, socket}, state) do
    sockets = MapSet.delete(state.sockets, socket)
    send(state.owner, {:wirekeeper_test_server, :closed, self(), MapSet.size(sockets)})
    {:noreply, %{state | sockets: sockets}}
  end

  def handle_info({:tcp_error, socket, reason}, state) do
    sockets = MapSet.delete(state.sockets, socket)
    send(state.owner, {:wirekeeper_test_server, :error, self(), reason})
    {:noreply, %{state | sockets: sockets}}
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.sockets, &:gen_tcp.close/1)
    :gen_tcp.close(state.listener)
    :ok
  end

  defp accept_loop(listener, server) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        :ok = :gen_tcp.controlling_process(socket, server)
        send(server, {:accepted, socket})
        accept_loop(listener, server)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        send(server, {:accept_error, reason})
    end
  end

  defp send_to_socket(socket, data, :ok) do
    case :gen_tcp.send(socket, data) do
      :ok -> {:cont, :ok}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end
end
