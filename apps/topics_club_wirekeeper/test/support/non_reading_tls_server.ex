defmodule TopicsClub.Wirekeeper.NonReadingTlsServer do
  @moduledoc false

  use GenServer

  def start_link(owner), do: GenServer.start_link(__MODULE__, owner)

  def port(server), do: GenServer.call(server, :port)

  @impl true
  def init(owner) do
    certificates = TopicsClub.Wirekeeper.TestCertificate.ensure!()

    {:ok, listener} =
      :ssl.listen(0,
        mode: :binary,
        packet: :raw,
        active: false,
        reuseaddr: true,
        recbuf: 1_024,
        ip: {127, 0, 0, 1},
        certfile: certificates.server_certificate,
        keyfile: certificates.server_key
      )

    {:ok, {_address, port}} = :ssl.sockname(listener)
    server = self()
    _acceptor = spawn_link(fn -> accept_once(listener, server) end)
    {:ok, %{listener: listener, owner: owner, port: port, socket: nil}}
  end

  @impl true
  def handle_call(:port, _from, state), do: {:reply, state.port, state}

  @impl true
  def handle_info({:accepted, socket}, state) do
    send(state.owner, {:wirekeeper_non_reading_tls_server, :accepted, self()})
    {:noreply, %{state | socket: socket}}
  end

  @impl true
  def terminate(_reason, state) do
    if state.socket, do: :ssl.close(state.socket)
    :ssl.close(state.listener)
    :ok
  end

  defp accept_once(listener, server) do
    with {:ok, transport_socket} <- :ssl.transport_accept(listener),
         {:ok, socket} <- :ssl.handshake(transport_socket, 5_000),
         :ok <- :ssl.controlling_process(socket, server) do
      send(server, {:accepted, socket})
    else
      {:error, reason} -> send(server, {:accept_error, reason})
    end
  end
end
