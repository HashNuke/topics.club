defmodule TopicsClub.Wirekeeper.Connection do
  @moduledoc false

  use GenServer

  alias TopicsClub.Wirekeeper.Socket

  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :key), Keyword.fetch!(opts, :generation)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def identity(connection), do: GenServer.call(connection, :identity)
  def info(connection), do: GenServer.call(connection, :info)

  def attach(connection, generation, consumer) do
    GenServer.call(connection, {:attach, generation, consumer})
  end

  def detach(connection, generation, consumer) do
    GenServer.call(connection, {:detach, generation, consumer})
  end

  def send_data(connection, generation, data) do
    GenServer.call(connection, {:send_data, generation, data})
  end

  def close(connection, generation) do
    GenServer.call(connection, {:close, generation})
  end

  @impl true
  def init(opts) do
    {adapter, adapter_opts} = Keyword.fetch!(opts, :protocol_adapter)

    with true <- protocol_adapter?(adapter),
         {:ok, adapter_state} <- adapter.init(adapter_opts),
         {:ok, socket} <- Socket.connect(Keyword.fetch!(opts, :transport)),
         :ok <- Socket.arm(socket) do
      {:ok,
       %{
         key: Keyword.fetch!(opts, :key),
         generation: Keyword.fetch!(opts, :generation),
         socket: socket,
         adapter: adapter,
         adapter_state: adapter_state,
         consumer: nil,
         consumer_ref: nil,
         detached_at: monotonic_ms(),
         detached_episode?: false,
         discarded_frames: 0,
         discarded_bytes: 0
       }}
    else
      false -> {:stop, :invalid_protocol_adapter}
      {:error, reason} -> {:stop, {:transport, reason}}
    end
  end

  @impl true
  def handle_call(:identity, _from, state) do
    {:reply, {:ok, state.key, state.generation}, state}
  end

  def handle_call(:info, _from, state) do
    {:reply, {:ok, connection_info(state)}, state}
  end

  def handle_call({:attach, generation, consumer}, _from, state) do
    cond do
      generation != state.generation ->
        {:reply, {:error, :stale_generation}, state}

      not is_pid(consumer) ->
        {:reply, {:error, :invalid_consumer}, state}

      state.consumer == consumer ->
        {:reply, {:ok, empty_gap(state)}, state}

      is_pid(state.consumer) ->
        {:reply, {:error, :already_attached}, state}

      true ->
        gap = gap_summary(state)
        consumer_ref = Process.monitor(consumer)

        {:reply, {:ok, gap},
         %{
           state
           | consumer: consumer,
             consumer_ref: consumer_ref,
             detached_episode?: false,
             discarded_frames: 0,
             discarded_bytes: 0
         }}
    end
  end

  def handle_call({:detach, generation, consumer}, _from, state) do
    cond do
      generation != state.generation ->
        {:reply, {:error, :stale_generation}, state}

      state.consumer != consumer ->
        {:reply, {:error, :not_attached}, state}

      true ->
        Process.demonitor(state.consumer_ref, [:flush])
        {:reply, :ok, begin_detached_episode(state)}
    end
  end

  def handle_call({:send_data, generation, data}, _from, state) do
    if generation == state.generation do
      case Socket.send(state.socket, data) do
        :ok ->
          {:reply, :ok, state}

        {:error, reason} ->
          notify_upstream_closed(state, {:transport_error, reason})
          {:stop, :normal, {:error, {:transport, reason}}, state}
      end
    else
      {:reply, {:error, :stale_generation}, state}
    end
  end

  def handle_call({:close, generation}, _from, state) do
    if generation == state.generation do
      :ok = Socket.close(state.socket)
      {:stop, :normal, :ok, state}
    else
      {:reply, {:error, :stale_generation}, state}
    end
  end

  @impl true
  def handle_info(
        {:DOWN, consumer_ref, :process, consumer, _reason},
        %{consumer: consumer, consumer_ref: consumer_ref} = state
      ) do
    {:noreply, begin_detached_episode(state)}
  end

  def handle_info({:tcp, socket, data}, %{socket: {:tcp, socket}} = state) do
    handle_inbound(data, state)
  end

  def handle_info({:ssl, socket, data}, %{socket: {:tls, socket}} = state) do
    handle_inbound(data, state)
  end

  def handle_info({:tcp_closed, socket}, %{socket: {:tcp, socket}} = state) do
    notify_upstream_closed(state, :closed)
    {:stop, :normal, state}
  end

  def handle_info({:ssl_closed, socket}, %{socket: {:tls, socket}} = state) do
    notify_upstream_closed(state, :closed)
    {:stop, :normal, state}
  end

  def handle_info({:tcp_error, socket, reason}, %{socket: {:tcp, socket}} = state) do
    notify_upstream_closed(state, {:transport_error, reason})
    {:stop, :normal, state}
  end

  def handle_info({:ssl_error, socket, reason}, %{socket: {:tls, socket}} = state) do
    notify_upstream_closed(state, {:transport_error, reason})
    {:stop, :normal, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    _result = Socket.close(state.socket)
    :ok
  end

  defp handle_inbound(data, state) do
    case state.adapter.handle_inbound(data, state.adapter_state) do
      {:ok, actions, adapter_state} when is_list(actions) ->
        state = %{state | adapter_state: adapter_state}

        case apply_actions(actions, state) do
          {:ok, state} ->
            case Socket.arm(state.socket) do
              :ok -> {:noreply, state}
              {:error, reason} -> stop_for_transport_error(state, reason)
            end

          {:error, reason, state} ->
            stop_for_transport_error(state, reason)
        end

      {:error, reason, adapter_state} ->
        state = %{state | adapter_state: adapter_state}
        notify_upstream_closed(state, {:protocol_error, reason})
        {:stop, :normal, state}

      _invalid_result ->
        notify_upstream_closed(state, {:protocol_error, :invalid_adapter_result})
        {:stop, :normal, state}
    end
  end

  defp apply_actions(actions, state) do
    Enum.reduce_while(actions, {:ok, state}, fn
      {:reply, data}, {:ok, current_state} ->
        case Socket.send(current_state.socket, data) do
          :ok -> {:cont, {:ok, current_state}}
          {:error, reason} -> {:halt, {:error, reason, current_state}}
        end

      {:forward, data}, {:ok, %{consumer: consumer} = current_state}
      when is_pid(consumer) and is_binary(data) ->
        send(consumer, {
          :topics_club_wirekeeper,
          {:data,
           %{
             key: current_state.key,
             generation: current_state.generation,
             payload: data
           }}
        })

        {:cont, {:ok, current_state}}

      {:forward, data}, {:ok, current_state} when is_binary(data) ->
        {:cont,
         {:ok,
          %{
            current_state
            | discarded_frames: current_state.discarded_frames + 1,
              discarded_bytes: current_state.discarded_bytes + byte_size(data)
          }}}

      _invalid_action, {:ok, current_state} ->
        {:halt, {:error, :invalid_adapter_action, current_state}}
    end)
  end

  defp stop_for_transport_error(state, reason) do
    notify_upstream_closed(state, {:transport_error, reason})
    {:stop, :normal, state}
  end

  defp notify_upstream_closed(%{consumer: consumer} = state, reason) when is_pid(consumer) do
    send(consumer, {
      :topics_club_wirekeeper,
      {:upstream_closed, %{key: state.key, generation: state.generation, reason: reason}}
    })

    :ok
  end

  defp notify_upstream_closed(_state, _reason), do: :ok

  defp begin_detached_episode(state) do
    %{
      state
      | consumer: nil,
        consumer_ref: nil,
        detached_at: monotonic_ms(),
        detached_episode?: true,
        discarded_frames: 0,
        discarded_bytes: 0
    }
  end

  defp connection_info(state) do
    %{
      key: state.key,
      generation: state.generation,
      transport: Socket.transport_name(state.socket),
      attached?: is_pid(state.consumer),
      discarded_frames: state.discarded_frames,
      discarded_bytes: state.discarded_bytes,
      detached_for_ms: detached_for_ms(state)
    }
  end

  defp gap_summary(state) do
    %{
      key: state.key,
      generation: state.generation,
      gap?: state.detached_episode? or state.discarded_frames > 0,
      discarded_frames: state.discarded_frames,
      discarded_bytes: state.discarded_bytes,
      detached_for_ms:
        if(state.detached_episode? or state.discarded_frames > 0,
          do: detached_for_ms(state),
          else: 0
        )
    }
  end

  defp empty_gap(state) do
    %{
      key: state.key,
      generation: state.generation,
      gap?: false,
      discarded_frames: 0,
      discarded_bytes: 0,
      detached_for_ms: 0
    }
  end

  defp detached_for_ms(%{consumer: consumer}) when is_pid(consumer), do: 0
  defp detached_for_ms(state), do: max(monotonic_ms() - state.detached_at, 0)

  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  defp protocol_adapter?(adapter) do
    Code.ensure_loaded?(adapter) and function_exported?(adapter, :init, 1) and
      function_exported?(adapter, :handle_inbound, 2)
  end
end
