defmodule TopicsClub.Wirekeeper.TestTlsServer do
  @moduledoc false

  use GenServer

  def start_link(owner) do
    GenServer.start_link(__MODULE__, owner)
  end

  def port(server), do: GenServer.call(server, :port)
  def send_data(server, data), do: GenServer.call(server, {:send_data, data})

  @impl true
  def init(owner) do
    certificates = TopicsClub.Wirekeeper.TestCertificate.ensure!()

    options = [
      :binary,
      packet: :raw,
      active: false,
      reuseaddr: true,
      ip: {127, 0, 0, 1},
      certfile: certificates.server_certificate,
      keyfile: certificates.server_key
    ]

    {:ok, listener} = :ssl.listen(0, options)
    {:ok, {_address, port}} = :ssl.sockname(listener)
    server = self()
    _acceptor = spawn_link(fn -> accept_loop(listener, server) end)

    {:ok, %{listener: listener, owner: owner, port: port, sockets: MapSet.new()}}
  end

  @impl true
  def handle_call(:port, _from, state), do: {:reply, state.port, state}

  def handle_call({:send_data, data}, _from, state) do
    result = Enum.reduce_while(state.sockets, :ok, &send_to_socket(&1, data, &2))
    {:reply, result, state}
  end

  @impl true
  def handle_info({:accepted, socket}, state) do
    :ok = :ssl.setopts(socket, active: :once)
    sockets = MapSet.put(state.sockets, socket)
    send(state.owner, {:wirekeeper_test_tls_server, :accepted, self()})
    {:noreply, %{state | sockets: sockets}}
  end

  def handle_info({:ssl, socket, data}, state) do
    send(state.owner, {:wirekeeper_test_tls_server, :data, self(), data})
    :ok = :ssl.setopts(socket, active: :once)
    {:noreply, state}
  end

  def handle_info({:ssl_closed, socket}, state) do
    {:noreply, %{state | sockets: MapSet.delete(state.sockets, socket)}}
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.sockets, &:ssl.close/1)
    :ssl.close(state.listener)
    :ok
  end

  defp accept_loop(listener, server) do
    case :ssl.transport_accept(listener) do
      {:ok, transport_socket} ->
        case :ssl.handshake(transport_socket, 5_000) do
          {:ok, socket} ->
            :ok = :ssl.controlling_process(socket, server)
            send(server, {:accepted, socket})
            accept_loop(listener, server)

          {:error, reason} ->
            send(server, {:handshake_error, reason})
        end

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        send(server, {:accept_error, reason})
    end
  end

  defp send_to_socket(socket, data, :ok) do
    case :ssl.send(socket, data) do
      :ok -> {:cont, :ok}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end
end
