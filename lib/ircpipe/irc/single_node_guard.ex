defmodule Ircpipe.Irc.SingleNodeGuard do
  @moduledoc false

  use GenServer

  require Logger

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def ensure_single_node do
    case Node.list(:visible) do
      [] -> :ok
      _nodes -> {:error, :multi_node_irc_not_supported}
    end
  end

  @impl true
  def init(_opts) do
    :ok = :net_kernel.monitor_nodes(true, node_type: :visible)
    {:ok, %{connected_nodes: MapSet.new(Node.list(:visible))}}
  end

  @impl true
  def handle_info({:nodeup, connected_node, _info}, state) when connected_node == node() do
    {:noreply, state}
  end

  def handle_info({:nodeup, connected_node, _info}, state) do
    connected_nodes = MapSet.put(state.connected_nodes, connected_node)

    if MapSet.size(state.connected_nodes) == 0 do
      Logger.error(
        "IRC session subsystem stopped because multi-node deployment is unsupported: #{inspect(connected_node)}"
      )

      {:stop, {:multi_node_irc_not_supported, connected_node},
       %{state | connected_nodes: connected_nodes}}
    else
      {:noreply, %{state | connected_nodes: connected_nodes}}
    end
  end

  def handle_info({:nodedown, disconnected_node, _info}, state)
      when disconnected_node == node() do
    {:noreply, state}
  end

  def handle_info({:nodedown, disconnected_node, _info}, state) do
    connected_nodes = MapSet.delete(state.connected_nodes, disconnected_node)

    if MapSet.size(state.connected_nodes) > 0 and MapSet.size(connected_nodes) == 0 do
      Logger.info("Single-node topology restored; restarting the IRC session subsystem")
      {:stop, :single_node_topology_restored, %{state | connected_nodes: connected_nodes}}
    else
      {:noreply, %{state | connected_nodes: connected_nodes}}
    end
  end
end
