defmodule TopicsClub.Wirekeeper.NonReadingTcpServer do
  @moduledoc false

  use GenServer

  def start_link(owner), do: GenServer.start_link(__MODULE__, owner)

  def port(server), do: GenServer.call(server, :port)

  @impl true
  def init(owner) do
    {:ok, listener} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :raw,
        active: false,
        reuseaddr: true,
        recbuf: 1_024
      ])

    {:ok, {_address, port}} = :inet.sockname(listener)
    server = self()
    _acceptor = spawn_link(fn -> accept_once(listener, server) end)
    {:ok, %{listener: listener, owner: owner, port: port, socket: nil}}
  end

  @impl true
  def handle_call(:port, _from, state), do: {:reply, state.port, state}

  @impl true
  def handle_info({:accepted, socket}, state) do
    send(state.owner, {:wirekeeper_non_reading_server, :accepted, self()})
    {:noreply, %{state | socket: socket}}
  end

  @impl true
  def terminate(_reason, state) do
    if state.socket, do: :gen_tcp.close(state.socket)
    :gen_tcp.close(state.listener)
    :ok
  end

  defp accept_once(listener, server) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        :ok = :gen_tcp.controlling_process(socket, server)
        send(server, {:accepted, socket})

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        send(server, {:accept_error, reason})
    end
  end
end
