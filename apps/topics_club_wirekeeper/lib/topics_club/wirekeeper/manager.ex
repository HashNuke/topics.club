defmodule TopicsClub.Wirekeeper.Manager do
  @moduledoc false

  use GenServer

  alias TopicsClub.Wirekeeper.{Connection, ConnectionSupervisor}

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def open(key, transport, opts) do
    GenServer.call(__MODULE__, {:open, key, transport, opts}, :infinity)
  end

  def lookup(key), do: GenServer.call(__MODULE__, {:lookup, key})
  def connections, do: GenServer.call(__MODULE__, :connections)

  @impl true
  def init(_opts) do
    {:ok, rebuild_connections()}
  end

  @impl true
  def handle_call({:open, key, transport, opts}, _from, state) do
    cond do
      not valid_key?(key) ->
        {:reply, {:error, :invalid_key}, state}

      Map.has_key?(state.connections, key) ->
        {:reply, {:error, :already_open}, state}

      true ->
        generation = generate_generation()

        child_opts = [
          key: key,
          generation: generation,
          transport: transport,
          protocol_adapter:
            Keyword.get(
              opts,
              :protocol_adapter,
              {TopicsClub.Wirekeeper.ProtocolAdapter.Passthrough, []}
            )
        ]

        case DynamicSupervisor.start_child(ConnectionSupervisor, {Connection, child_opts}) do
          {:ok, connection} ->
            monitor_ref = Process.monitor(connection)
            entry = %{pid: connection, monitor_ref: monitor_ref}
            state = put_in(state, [:connections, key], entry)
            {:reply, Connection.info(connection), state}

          {:error, {:transport, reason}} ->
            {:reply, {:error, {:transport, reason}}, state}

          {:error, reason} ->
            {:reply, {:error, normalize_start_error(reason)}, state}
        end
    end
  end

  def handle_call({:lookup, key}, _from, state) do
    case Map.fetch(state.connections, key) do
      {:ok, %{pid: connection}} -> {:reply, {:ok, connection}, state}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:connections, _from, state) do
    connections = Enum.map(state.connections, fn {_key, entry} -> entry.pid end)
    {:reply, connections, state}
  end

  @impl true
  def handle_info({:DOWN, monitor_ref, :process, connection, _reason}, state) do
    connections =
      Map.reject(state.connections, fn {_key, entry} ->
        entry.pid == connection and entry.monitor_ref == monitor_ref
      end)

    {:noreply, %{state | connections: connections}}
  end

  defp rebuild_connections do
    connections =
      ConnectionSupervisor
      |> DynamicSupervisor.which_children()
      |> Enum.reduce(%{}, fn
        {_id, connection, _type, _modules}, connections when is_pid(connection) ->
          case safe_identity(connection) do
            {:ok, key, _generation} ->
              Map.put(connections, key, %{
                pid: connection,
                monitor_ref: Process.monitor(connection)
              })

            :closed ->
              connections
          end

        _child, connections ->
          connections
      end)

    %{connections: connections}
  end

  defp safe_identity(connection) do
    Connection.identity(connection)
  catch
    :exit, _reason -> :closed
  end

  defp valid_key?(key), do: is_integer(key) or (is_binary(key) and byte_size(key) > 0)

  defp generate_generation do
    16
    |> :crypto.strong_rand_bytes()
    |> Base.encode16(case: :lower)
  end

  defp normalize_start_error({:shutdown, reason}), do: normalize_start_error(reason)
  defp normalize_start_error({:failed_to_start_child, _child, reason}), do: normalize_start_error(reason)
  defp normalize_start_error(reason) when is_atom(reason), do: reason
  defp normalize_start_error(_reason), do: :connection_start_failed
end
