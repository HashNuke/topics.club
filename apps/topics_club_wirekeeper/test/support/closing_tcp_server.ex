defmodule TopicsClub.Wirekeeper.ClosingTcpServer do
  @moduledoc false

  use GenServer

  def start_link(owner), do: GenServer.start_link(__MODULE__, owner)

  def port(server), do: GenServer.call(server, :port)

  @impl true
  def init(owner) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

    {:ok, {_address, port}} = :inet.sockname(listener)
    server = self()
    _acceptor = spawn_link(fn -> accept_loop(listener, server) end)
    {:ok, %{listener: listener, owner: owner, port: port, accepted: 0}}
  end

  @impl true
  def handle_call(:port, _from, state), do: {:reply, state.port, state}

  @impl true
  def handle_info(:accepted_and_closed, state) do
    accepted = state.accepted + 1
    send(state.owner, {:wirekeeper_closing_server, :accepted, self(), accepted})
    {:noreply, %{state | accepted: accepted}}
  end

  @impl true
  def terminate(_reason, state) do
    :gen_tcp.close(state.listener)
    :ok
  end

  defp accept_loop(listener, server) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        send(server, :accepted_and_closed)
        accept_loop(listener, server)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        send(server, {:accept_error, reason})
    end
  end
end
