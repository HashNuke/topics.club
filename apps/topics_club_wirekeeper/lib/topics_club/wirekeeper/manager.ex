defmodule TopicsClub.Wirekeeper.Manager do
  @moduledoc false

  use GenServer

  alias TopicsClub.Wirekeeper.{Connection, ConnectionSupervisor, OpenTaskSupervisor}

  @registry TopicsClub.Wirekeeper.ConnectionRegistry
  @max_pending_opens 8

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
    {:ok, %{opening_by_key: %{}, opening_by_ref: %{}}}
  end

  @impl true
  def handle_call({:open, key, transport, opts}, from, state) do
    cond do
      not valid_key?(key) ->
        {:reply, {:error, :invalid_key}, state}

      not is_list(opts) or not Keyword.keyword?(opts) ->
        {:reply, {:error, :invalid_options}, state}

      Map.has_key?(state.opening_by_key, key) or registered?(key) ->
        {:reply, {:error, :already_open}, state}

      map_size(state.opening_by_ref) >= @max_pending_opens ->
        {:reply, {:error, :overloaded}, state}

      true ->
        generation = generate_generation()
        child_opts = connection_options(key, generation, transport, opts)

        case start_open_task(child_opts) do
          {:ok, task} ->
            {caller_pid, _reply_tag} = from
            caller_ref = Process.monitor(caller_pid)

            opening = %{
              from: from,
              caller_ref: caller_ref,
              key: key,
              generation: generation,
              transport: transport,
              task_pid: task.pid
            }

            state = %{
              state
              | opening_by_key: Map.put(state.opening_by_key, key, task.ref),
                opening_by_ref: Map.put(state.opening_by_ref, task.ref, opening)
            }

            {:noreply, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:lookup, key}, _from, state) do
    reply =
      case Registry.lookup(@registry, key) do
        [{_connection, {:opening, _generation}}] -> {:error, :opening}
        [{connection, {_status, _generation}}] -> {:ok, connection}
        [] -> {:error, :not_found}
      end

    {:reply, reply, state}
  end

  def handle_call(:connections, _from, state) do
    connections =
      Registry.select(@registry, [
        {{:"$1", :"$2", :"$3"}, [], [{{:"$2", :"$3"}}]}
      ])
      |> Enum.flat_map(fn
        {connection, {status, _generation}} when status in [:open, :closed] -> [connection]
        {_connection, {:opening, _generation}} -> []
      end)

    {:reply, connections, state}
  end

  @impl true
  def handle_info({task_ref, result}, state) when is_reference(task_ref) do
    case Map.pop(state.opening_by_ref, task_ref) do
      {nil, _opening_by_ref} ->
        {:noreply, state}

      {opening, opening_by_ref} ->
        Process.demonitor(task_ref, [:flush])
        Process.demonitor(opening.caller_ref, [:flush])
        GenServer.reply(opening.from, normalize_open_result(result, opening))

        state = %{
          state
          | opening_by_key: Map.delete(state.opening_by_key, opening.key),
            opening_by_ref: opening_by_ref
        }

        {:noreply, state}
    end
  end

  def handle_info({:DOWN, task_ref, :process, task_pid, reason}, state) do
    case Map.get(state.opening_by_ref, task_ref) do
      %{task_pid: ^task_pid} = opening ->
        Process.demonitor(opening.caller_ref, [:flush])
        GenServer.reply(opening.from, {:error, normalize_task_error(reason)})

        state = %{
          state
          | opening_by_key: Map.delete(state.opening_by_key, opening.key),
            opening_by_ref: Map.delete(state.opening_by_ref, task_ref)
        }

        {:noreply, state}

      _unknown_task ->
        cancel_open_for_caller(task_ref, state)
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp connection_options(key, generation, transport, opts) do
    [
      key: key,
      generation: generation,
      transport: transport,
      buffer: Keyword.get(opts, :buffer, []),
      closed_retention_ms: Keyword.get(opts, :closed_retention_ms, 60_000),
      protocol_adapter:
        Keyword.get(
          opts,
          :protocol_adapter,
          {TopicsClub.Wirekeeper.ProtocolAdapter.Passthrough, []}
        )
    ]
  end

  defp start_open_task(child_opts) do
    task =
      Task.Supervisor.async_nolink(OpenTaskSupervisor, fn ->
        child_opts = Keyword.put(child_opts, :ready_recipient, self())

        case DynamicSupervisor.start_child(ConnectionSupervisor, {Connection, child_opts}) do
          {:ok, connection} -> await_connection_ready(connection)
          {:error, reason} -> {:error, reason}
        end
      end)

    {:ok, task}
  catch
    :exit, _reason -> {:error, :connection_start_failed}
  end

  defp await_connection_ready(connection) do
    connection_ref = Process.monitor(connection)

    receive do
      {:topics_club_wirekeeper_connection_ready, ^connection, :ok} ->
        Process.demonitor(connection_ref, [:flush])
        {:ok, connection}

      {:topics_club_wirekeeper_connection_ready, ^connection, {:error, reason}} ->
        Process.demonitor(connection_ref, [:flush])
        {:error, reason}

      {:DOWN, ^connection_ref, :process, ^connection, reason} ->
        {:error, reason}
    end
  end

  defp cancel_open_for_caller(caller_ref, state) do
    opening_entry =
      Enum.find(state.opening_by_ref, fn {_task_ref, opening} ->
        opening.caller_ref == caller_ref
      end)

    case opening_entry do
      nil ->
        {:noreply, state}

      {task_ref, opening} ->
        _result = Task.Supervisor.terminate_child(OpenTaskSupervisor, opening.task_pid)
        Process.demonitor(task_ref, [:flush])
        terminate_opening_connection(opening)

        state = %{
          state
          | opening_by_key: Map.delete(state.opening_by_key, opening.key),
            opening_by_ref: Map.delete(state.opening_by_ref, task_ref)
        }

        {:noreply, state}
    end
  end

  defp terminate_opening_connection(opening) do
    case Registry.lookup(@registry, opening.key) do
      [{connection, {_status, generation}}] when generation == opening.generation ->
        DynamicSupervisor.terminate_child(ConnectionSupervisor, connection)

      _missing_or_replaced ->
        :ok
    end
  end

  defp registered?(key), do: Registry.lookup(@registry, key) != []

  defp normalize_open_result({:ok, _connection}, opening) do
    {:ok,
     %{
       key: opening.key,
       generation: opening.generation,
       transport: transport_name(opening.transport),
       status: :open,
       upstream_closed_reason: nil,
       attached?: false,
       acked_through: 0,
       buffered_records: 0,
       buffered_bytes: 0,
       in_flight_records: 0,
       dropped_records: 0,
       dropped_bytes: 0,
       detached_for_ms: 0
     }}
  end

  defp normalize_open_result({:error, {:transport, reason}}, _opening) do
    {:error, {:transport, reason}}
  end

  defp normalize_open_result({:error, reason}, _opening) do
    {:error, normalize_start_error(reason)}
  end

  defp transport_name({transport, _opts}) when transport in [:tcp, :tls], do: transport
  defp transport_name(_invalid_transport), do: :tcp

  defp valid_key?(key), do: is_integer(key) or (is_binary(key) and byte_size(key) > 0)

  defp generate_generation do
    16
    |> :crypto.strong_rand_bytes()
    |> Base.encode16(case: :lower)
  end

  defp normalize_task_error(:normal), do: :connection_start_failed
  defp normalize_task_error(reason), do: normalize_start_error(reason)

  defp normalize_start_error({:shutdown, reason}), do: normalize_start_error(reason)

  defp normalize_start_error({:failed_to_start_child, _child, reason}),
    do: normalize_start_error(reason)

  defp normalize_start_error(reason) when is_atom(reason), do: reason
  defp normalize_start_error(_reason), do: :connection_start_failed
end
