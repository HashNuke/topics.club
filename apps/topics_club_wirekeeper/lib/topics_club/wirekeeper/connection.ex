defmodule TopicsClub.Wirekeeper.Connection do
  @moduledoc false

  use GenServer

  alias TopicsClub.Wirekeeper.{Buffer, Checkpoint, ConsumerWatcher, Delivery, Socket}

  @default_closed_retention_ms 60_000
  @default_checkpoint_max_bytes 65_536
  @registry TopicsClub.Wirekeeper.ConnectionRegistry

  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :key), Keyword.fetch!(opts, :generation)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def identity(connection), do: GenServer.call(connection, :identity)
  def info(connection), do: GenServer.call(connection, :info)

  def attach(connection, generation, consumer) do
    GenServer.call(connection, {:attach, generation, consumer})
  end

  def detach(connection, generation, consumer) do
    GenServer.call(connection, {:detach, generation, consumer})
  end

  def ack(connection, generation, sequence, consumer) do
    GenServer.call(connection, {:ack, generation, sequence, consumer})
  end

  def ack_with_checkpoint(connection, generation, sequence, checkpoint, consumer) do
    GenServer.call(
      connection,
      {:ack_with_checkpoint, generation, sequence, checkpoint, consumer}
    )
  end

  def put_checkpoint(connection, generation, checkpoint, consumer) do
    GenServer.call(connection, {:put_checkpoint, generation, checkpoint, consumer})
  end

  def send_data(connection, generation, data) do
    GenServer.call(connection, {:send_data, generation, data}, :infinity)
  end

  def close(connection, generation), do: GenServer.call(connection, {:close, generation})

  @impl true
  def init(opts) do
    key = Keyword.fetch!(opts, :key)
    generation = Keyword.fetch!(opts, :generation)
    transport_options = Keyword.fetch!(opts, :transport)
    ready_recipient = Keyword.get(opts, :ready_recipient)
    {adapter, adapter_opts} = Keyword.fetch!(opts, :protocol_adapter)
    closed_retention_ms = Keyword.get(opts, :closed_retention_ms, @default_closed_retention_ms)

    checkpoint_max_bytes =
      Keyword.get(opts, :checkpoint_max_bytes, @default_checkpoint_max_bytes)

    with true <- link_ready_recipient(ready_recipient),
         true <- protocol_adapter?(adapter),
         true <- positive_integer?(closed_retention_ms),
         true <- positive_integer?(checkpoint_max_bytes),
         {:ok, buffer} <- Buffer.new(Keyword.get(opts, :buffer, [])),
         {:ok, _registry_owner} <- Registry.register(@registry, key, {:opening, generation}) do
      {:ok,
       %{
         key: key,
         generation: generation,
         transport: transport_name(transport_options),
         transport_options: transport_options,
         ready_recipient: ready_recipient,
         socket: nil,
         status: :opening,
         upstream_closed_reason: nil,
         closed_retention_ms: closed_retention_ms,
         checkpoint_max_bytes: checkpoint_max_bytes,
         checkpoint: nil,
         checkpoint_sequence: nil,
         closed_timer_ref: nil,
         adapter: adapter,
         adapter_opts: adapter_opts,
         adapter_state: nil,
         delivery: Delivery,
         buffer: buffer,
         consumer: nil,
         consumer_watcher_spec: {ConsumerWatcher, []},
         consumer_watcher_pid: nil,
         consumer_ref: nil,
         acked_through: 0,
         in_flight: [],
         overflow_notification_pending?: false,
         closure_notified?: false,
         detached_at: monotonic_ms(),
         detached_episode?: false
       }, {:continue, :connect}}
    else
      false -> {:stop, :invalid_options}
      {:error, {:already_registered, _connection}} -> {:stop, :already_open}
      {:error, :invalid_buffer_options} -> {:stop, :invalid_buffer_options}
      {:error, reason} -> {:stop, {:transport, reason}}
    end
  end

  @impl true
  def handle_continue(:connect, state) do
    with {:ok, adapter_state} <- state.adapter.init(state.adapter_opts),
         {:ok, socket} <- Socket.connect(state.transport_options),
         :ok <- Socket.arm(socket) do
      {{:open, generation}, {:opening, generation}} =
        Registry.update_value(@registry, state.key, fn _old_value ->
          {:open, state.generation}
        end)

      state =
        state
        |> Map.merge(%{
          socket: socket,
          status: :open,
          transport: Socket.transport_name(socket),
          adapter_state: adapter_state,
          detached_at: monotonic_ms()
        })
        |> Map.delete(:transport_options)
        |> Map.delete(:adapter_opts)
        |> notify_ready(:ok)

      {:noreply, state}
    else
      {:error, reason} ->
        state = notify_ready(state, {:error, {:transport, reason}})
        {:stop, :normal, state}
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
        {:reply, {:ok, attach_retry_summary(state)}, state}

      is_pid(state.consumer) ->
        {:reply, {:error, :already_attached}, state}

      true ->
        replay = replay_summary(state)
        {consumer_watcher_pid, consumer_ref} = start_consumer_watcher(state, consumer)

        state =
          state
          |> Map.merge(%{
            consumer: consumer,
            consumer_watcher_pid: consumer_watcher_pid,
            consumer_ref: consumer_ref,
            in_flight: [],
            overflow_notification_pending?: false,
            closure_notified?: false,
            detached_episode?: false
          })
          |> dispatch_available()
          |> maybe_notify_closed()

        cond do
          not is_pid(state.consumer) ->
            {:reply, {:error, :consumer_unreachable}, state}

          state.status == :closed and state.buffer.records == 0 ->
            {:stop, :normal, {:ok, replay}, state}

          true ->
            {:reply, {:ok, replay}, state}
        end
    end
  end

  def handle_call({:detach, generation, consumer}, _from, state) do
    cond do
      generation != state.generation ->
        {:reply, {:error, :stale_generation}, state}

      not is_pid(consumer) ->
        {:reply, {:error, :invalid_consumer}, state}

      state.consumer != consumer or not is_reference(state.consumer_ref) ->
        {:reply, {:error, :not_attached}, state}

      true ->
        {:reply, :ok, begin_detached_episode(state)}
    end
  end

  def handle_call({:ack, generation, sequence, consumer}, _from, state) do
    cond do
      generation != state.generation ->
        {:reply, {:error, :stale_generation}, state}

      not is_pid(consumer) ->
        {:reply, {:error, :invalid_consumer}, state}

      state.consumer != consumer ->
        {:reply, {:error, :not_attached}, state}

      not is_integer(sequence) or sequence <= 0 ->
        {:reply, {:error, :invalid_ack}, state}

      sequence <= state.acked_through ->
        {:reply, :ok, state}

      is_integer(state.checkpoint_sequence) ->
        {:reply, {:error, :checkpoint_required}, state}

      sequence not in state.in_flight ->
        {:reply, {:error, :invalid_ack}, state}

      true ->
        state |> acknowledge_through(sequence) |> ack_reply()
    end
  end

  def handle_call(
        {:ack_with_checkpoint, generation, sequence, checkpoint, consumer},
        _from,
        state
      ) do
    cond do
      generation != state.generation ->
        {:reply, {:error, :stale_generation}, state}

      not is_pid(consumer) ->
        {:reply, {:error, :invalid_consumer}, state}

      state.consumer != consumer ->
        {:reply, {:error, :not_attached}, state}

      not is_integer(sequence) or sequence <= 0 ->
        {:reply, {:error, :invalid_ack}, state}

      sequence <= state.acked_through ->
        if is_integer(state.checkpoint_sequence) and state.checkpoint_sequence >= sequence do
          {:reply, :ok, state}
        else
          {:reply, {:error, :checkpoint_not_recorded}, state}
        end

      sequence not in state.in_flight ->
        {:reply, {:error, :invalid_ack}, state}

      true ->
        case Checkpoint.encode(checkpoint, state.checkpoint_max_bytes) do
          {:ok, encoded} ->
            state
            |> Map.merge(%{checkpoint: encoded, checkpoint_sequence: sequence})
            |> acknowledge_through(sequence)
            |> ack_reply()

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:put_checkpoint, generation, checkpoint, consumer}, _from, state) do
    cond do
      generation != state.generation ->
        {:reply, {:error, :stale_generation}, state}

      not is_pid(consumer) ->
        {:reply, {:error, :invalid_consumer}, state}

      state.consumer != consumer ->
        {:reply, {:error, :not_attached}, state}

      is_integer(state.checkpoint_sequence) ->
        {:reply, {:error, :checkpoint_ack_required}, state}

      true ->
        case Checkpoint.encode(checkpoint, state.checkpoint_max_bytes) do
          {:ok, encoded} -> {:reply, :ok, %{state | checkpoint: encoded}}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:send_data, generation, data}, _from, state) do
    cond do
      generation != state.generation ->
        {:reply, {:error, :stale_generation}, state}

      state.status == :closed ->
        {:reply, {:error, :upstream_closed}, state}

      not valid_iodata?(data) ->
        {:reply, {:error, :invalid_data}, state}

      true ->
        case Socket.send(state.socket, data) do
          :ok ->
            {:reply, :ok, state}

          {:error, reason} ->
            state = transition_closed(state, {:transport_error, reason})
            reply_or_stop_closed({:error, {:transport, reason}}, state)
        end
    end
  end

  def handle_call({:close, generation}, _from, state) do
    if generation == state.generation do
      close_socket(state.socket)
      {:stop, :normal, :ok, state}
    else
      {:reply, {:error, :stale_generation}, state}
    end
  end

  @impl true
  def handle_info(
        {:topics_club_wirekeeper_consumer_down, consumer_watcher_pid, consumer, _reason},
        %{consumer: consumer, consumer_watcher_pid: consumer_watcher_pid} = state
      ) do
    {:noreply, begin_detached_episode(state)}
  end

  def handle_info(
        {:DOWN, consumer_ref, :process, consumer_watcher_pid, _reason},
        %{consumer_ref: consumer_ref, consumer_watcher_pid: consumer_watcher_pid} = state
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
    handle_upstream_closed(:closed, state)
  end

  def handle_info({:ssl_closed, socket}, %{socket: {:tls, socket}} = state) do
    handle_upstream_closed(:closed, state)
  end

  def handle_info({:tcp_error, socket, reason}, %{socket: {:tcp, socket}} = state) do
    handle_upstream_closed({:transport_error, reason}, state)
  end

  def handle_info({:ssl_error, socket, reason}, %{socket: {:tls, socket}} = state) do
    handle_upstream_closed({:transport_error, reason}, state)
  end

  def handle_info({:closed_retention_expired, timer_ref}, %{closed_timer_ref: timer_ref} = state) do
    {:stop, :normal, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    _state = stop_consumer_watcher(state)
    close_socket(state.socket)
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
              {:error, reason} -> handle_upstream_closed({:transport_error, reason}, state)
            end

          {:error, reason, state} ->
            handle_upstream_closed({:transport_error, reason}, state)
        end

      {:error, reason, actions, adapter_state} when is_list(actions) ->
        state = %{state | adapter_state: adapter_state}

        case apply_actions(actions, state) do
          {:ok, state} ->
            handle_upstream_closed({:protocol_error, reason}, state)

          {:error, transport_reason, state} ->
            handle_upstream_closed({:transport_error, transport_reason}, state)
        end

      {:error, reason, adapter_state} ->
        state = %{state | adapter_state: adapter_state}
        handle_upstream_closed({:protocol_error, reason}, state)

      _invalid_result ->
        handle_upstream_closed({:protocol_error, :invalid_adapter_result}, state)
    end
  end

  defp apply_actions(actions, state) do
    Enum.reduce_while(actions, {:ok, state}, fn
      {:reply, data}, {:ok, current_state} ->
        case Socket.send(current_state.socket, data) do
          :ok -> {:cont, {:ok, current_state}}
          {:error, reason} -> {:halt, {:error, reason, current_state}}
        end

      {:forward, data}, {:ok, current_state} when is_binary(data) ->
        {buffer, _sequence, overflow} = Buffer.push(current_state.buffer, data)

        current_state =
          current_state
          |> Map.put(:buffer, buffer)
          |> notify_overflow(overflow)
          |> dispatch_available()

        {:cont, {:ok, current_state}}

      _invalid_action, {:ok, current_state} ->
        {:halt, {:error, :invalid_adapter_action, current_state}}
    end)
  end

  defp dispatch_available(%{consumer: consumer} = state) when is_pid(consumer) do
    available_slots = max(state.buffer.max_in_flight - length(state.in_flight), 0)
    in_flight = MapSet.new(state.in_flight)

    records =
      state.buffer
      |> Buffer.records()
      |> Enum.reject(fn {sequence, _payload} -> MapSet.member?(in_flight, sequence) end)
      |> Enum.take(available_slots)

    Enum.reduce_while(records, state, fn {sequence, payload}, current_state ->
      message =
        {:topics_club_wirekeeper,
         {:data,
          %{
            key: current_state.key,
            generation: current_state.generation,
            sequence: sequence,
            payload: payload
          }}}

      case deliver_to_consumer(current_state, message) do
        {:ok, current_state} ->
          {:cont, %{current_state | in_flight: current_state.in_flight ++ [sequence]}}

        {:error, current_state} ->
          {:halt, current_state}
      end
    end)
  end

  defp dispatch_available(state), do: state

  defp notify_overflow(state, %{records: 0}), do: state

  defp notify_overflow(%{overflow_notification_pending?: true} = state, _overflow), do: state

  defp notify_overflow(%{consumer: consumer} = state, overflow) when is_pid(consumer) do
    totals = Buffer.info(state.buffer)

    message =
      {:topics_club_wirekeeper,
       {:overflow,
        %{
          key: state.key,
          generation: state.generation,
          dropped_records: overflow.records,
          dropped_bytes: overflow.bytes,
          total_dropped_records: totals.dropped_records,
          total_dropped_bytes: totals.dropped_bytes
        }}}

    case deliver_to_consumer(state, message) do
      {:ok, state} -> %{state | overflow_notification_pending?: true}
      {:error, state} -> state
    end
  end

  defp notify_overflow(state, _overflow), do: state

  defp handle_upstream_closed(reason, state) do
    state = transition_closed(state, reason)

    if is_pid(state.consumer) and state.buffer.records == 0 do
      {:stop, :normal, state}
    else
      {:noreply, state}
    end
  end

  defp transition_closed(%{status: :closed} = state, _reason), do: state

  defp transition_closed(state, reason) do
    close_socket(state.socket)
    timer_ref = make_ref()

    _timer =
      Process.send_after(
        self(),
        {:closed_retention_expired, timer_ref},
        state.closed_retention_ms
      )

    _updated =
      Registry.update_value(@registry, state.key, fn _old_value ->
        {:closed, state.generation}
      end)

    state
    |> Map.merge(%{
      socket: nil,
      status: :closed,
      upstream_closed_reason: reason,
      closed_timer_ref: timer_ref
    })
    |> maybe_notify_closed()
  end

  defp maybe_notify_closed(%{status: :closed, consumer: consumer} = state)
       when is_pid(consumer) do
    in_flight = MapSet.new(state.in_flight)

    all_records_dispatched? =
      Enum.all?(Buffer.records(state.buffer), fn {sequence, _payload} ->
        MapSet.member?(in_flight, sequence)
      end)

    if not state.closure_notified? and all_records_dispatched? do
      message =
        {:topics_club_wirekeeper,
         {:upstream_closed,
          %{
            key: state.key,
            generation: state.generation,
            reason: state.upstream_closed_reason
          }}}

      case deliver_to_consumer(state, message) do
        {:ok, state} -> %{state | closure_notified?: true}
        {:error, state} -> state
      end
    else
      state
    end
  end

  defp maybe_notify_closed(state), do: state

  defp reply_or_stop_closed(reply, state) do
    state = maybe_notify_closed(state)

    if is_pid(state.consumer) and state.buffer.records == 0 do
      {:stop, :normal, reply, state}
    else
      {:reply, reply, state}
    end
  end

  defp begin_detached_episode(state) do
    state = stop_consumer_watcher(state)

    %{
      state
      | consumer: nil,
        consumer_watcher_pid: nil,
        consumer_ref: nil,
        in_flight: [],
        overflow_notification_pending?: false,
        closure_notified?: false,
        detached_at: monotonic_ms(),
        detached_episode?: true
    }
  end

  defp deliver_to_consumer(state, message) do
    case state.delivery.send(state.consumer, message) do
      :ok -> {:ok, state}
      reason when reason in [:nosuspend, :noconnect] -> {:error, detach_consumer(state)}
    end
  end

  defp detach_consumer(state) do
    begin_detached_episode(state)
  end

  defp start_consumer_watcher(state, consumer) do
    {watcher, opts} = state.consumer_watcher_spec
    watcher.start(self(), consumer, opts)
  end

  defp stop_consumer_watcher(state) do
    if is_reference(state.consumer_ref) do
      Process.demonitor(state.consumer_ref, [:flush])
    end

    if is_pid(state.consumer_watcher_pid) do
      Process.exit(state.consumer_watcher_pid, :kill)
    end

    state
  end

  defp acknowledge_through(state, sequence) do
    state
    |> Map.merge(%{
      buffer: Buffer.delete_through(state.buffer, sequence),
      acked_through: sequence,
      in_flight: Enum.reject(state.in_flight, &(&1 <= sequence)),
      overflow_notification_pending?: false
    })
    |> dispatch_available()
    |> maybe_notify_closed()
  end

  defp ack_reply(state) do
    if state.status == :closed and state.buffer.records == 0 and is_pid(state.consumer) do
      {:stop, :normal, :ok, state}
    else
      {:reply, :ok, state}
    end
  end

  defp connection_info(state) do
    Map.merge(
      %{
        key: state.key,
        generation: state.generation,
        transport: state.transport,
        status: state.status,
        upstream_closed_reason: state.upstream_closed_reason,
        attached?: is_pid(state.consumer),
        acked_through: state.acked_through,
        in_flight_records: length(state.in_flight),
        detached_for_ms: detached_for_ms(state)
      },
      Buffer.info(state.buffer)
    )
  end

  defp replay_summary(state) do
    buffer_info = Buffer.info(state.buffer)

    %{
      key: state.key,
      generation: state.generation,
      delivery_guarantee: :at_least_once,
      gap?: buffer_info.dropped_records > 0,
      replayed_records: buffer_info.buffered_records,
      replayed_bytes: buffer_info.buffered_bytes,
      dropped_records: buffer_info.dropped_records,
      dropped_bytes: buffer_info.dropped_bytes,
      detached_for_ms: detached_for_ms(state),
      checkpoint: Checkpoint.decode(state.checkpoint)
    }
  end

  defp attach_retry_summary(state) do
    buffer_info = Buffer.info(state.buffer)

    %{
      key: state.key,
      generation: state.generation,
      delivery_guarantee: :at_least_once,
      gap?: buffer_info.dropped_records > 0 or buffer_info.dropped_bytes > 0,
      replayed_records: 0,
      replayed_bytes: 0,
      dropped_records: buffer_info.dropped_records,
      dropped_bytes: buffer_info.dropped_bytes,
      detached_for_ms: 0,
      checkpoint: Checkpoint.decode(state.checkpoint)
    }
  end

  defp detached_for_ms(%{consumer: consumer}) when is_pid(consumer), do: 0
  defp detached_for_ms(state), do: max(monotonic_ms() - state.detached_at, 0)

  defp close_socket(nil), do: :ok
  defp close_socket(socket), do: Socket.close(socket)

  defp notify_ready(%{ready_recipient: recipient} = state, result) when is_pid(recipient) do
    send(recipient, {:topics_club_wirekeeper_connection_ready, self(), result})
    %{state | ready_recipient: nil}
  end

  defp notify_ready(state, _result), do: state

  defp transport_name({transport, _opts}) when transport in [:tcp, :tls], do: transport
  defp transport_name(_transport), do: :tcp

  defp link_ready_recipient(recipient) when is_pid(recipient), do: Process.link(recipient)
  defp link_ready_recipient(nil), do: true
  defp link_ready_recipient(_recipient), do: false

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
  defp positive_integer?(value), do: is_integer(value) and value > 0

  defp valid_iodata?(data) do
    _size = :erlang.iolist_size(data)
    true
  rescue
    ArgumentError -> false
  end

  defp protocol_adapter?(adapter) do
    Code.ensure_loaded?(adapter) and function_exported?(adapter, :init, 1) and
      function_exported?(adapter, :handle_inbound, 2)
  end
end
