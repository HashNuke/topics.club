defmodule TopicsClub.Irc.IngestionClaimReleaser do
  @moduledoc false

  use GenServer

  require Logger

  alias TopicsClub.Chat.IrcIngestionEffect
  alias TopicsClub.Irc.WirekeeperTransport

  @default_flush_interval 25
  @default_recovery_interval 60_000
  @retry_interval 1_000
  @batch_size 100

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def release(connection_id, generation, sequence) do
    GenServer.cast(__MODULE__, {:release, {connection_id, generation, sequence}})
  catch
    :exit, _reason -> :ok
  end

  @doc false
  def flush do
    GenServer.call(__MODULE__, :flush)
  catch
    :exit, _reason -> :ok
  end

  @doc false
  def recover(server \\ __MODULE__), do: GenServer.call(server, :recover)

  @impl true
  def init(opts) do
    flush_interval =
      Keyword.get(
        opts,
        :flush_interval,
        Application.get_env(
          :topics_club_engine,
          :ingestion_claim_release_interval,
          @default_flush_interval
        )
      )

    recovery_interval =
      Keyword.get(
        opts,
        :recovery_interval,
        Application.get_env(
          :topics_club_engine,
          :ingestion_claim_recovery_interval,
          @default_recovery_interval
        )
      )

    state = %{
      pending: MapSet.new(),
      timer: nil,
      flush_interval: flush_interval,
      recovery_cursor: nil,
      recovery_interval: recovery_interval,
      recovery_timer: nil
    }

    if recovery_interval != :disabled and Keyword.get(opts, :recover_on_start?, true),
      do: send(self(), :recover)

    {:ok, state}
  end

  @impl true
  def handle_cast({:release, _claim}, %{flush_interval: :disabled} = state),
    do: {:noreply, state}

  def handle_cast({:release, claim}, state) do
    state = %{state | pending: MapSet.put(state.pending, claim)}

    state =
      if MapSet.size(state.pending) >= @batch_size do
        state |> cancel_timer() |> schedule_flush(0)
      else
        schedule_automatic_flush(state)
      end

    {:noreply, state}
  end

  @impl true
  def handle_call(:flush, _from, state) do
    {result, state} = flush_pending(state)
    {:reply, result, state}
  end

  def handle_call(:recover, _from, state) do
    {result, state} = recover_batch(%{state | recovery_cursor: nil})
    {:reply, result, state}
  end

  @impl true
  def handle_info(:flush, state) do
    {_result, state} = flush_pending(%{state | timer: nil})
    {:noreply, state}
  end

  def handle_info(:recover, state) do
    {_result, state} = recover_batch(%{state | recovery_timer: nil})
    {:noreply, schedule_recovery(state)}
  end

  defp flush_pending(state) do
    state = cancel_timer(state)

    if MapSet.size(state.pending) == 0 do
      {:ok, state}
    else
      case IrcIngestionEffect.release_many(MapSet.to_list(state.pending)) do
        :ok -> {:ok, %{state | pending: MapSet.new()}}
        {:error, reason} -> {{:error, reason}, retry(state, reason)}
      end
    end
  end

  defp retry(state, reason) do
    Logger.warning("Could not release acknowledged IRC ingestion claims",
      event: :irc_ingestion_claim_release_failed,
      claim_count: MapSet.size(state.pending),
      reason: inspect(reason)
    )

    case state.flush_interval do
      :manual -> state
      _interval -> schedule_flush(state, @retry_interval)
    end
  end

  defp recover_batch(state) do
    generations =
      IrcIngestionEffect.pending_generations(state.recovery_cursor, @batch_size)

    result =
      Enum.reduce(
        generations,
        %{released_generations: 0, retained_generations: 0, errors: []},
        &recover_generation/2
      )

    cursor =
      case List.last(generations) do
        %{connection_id: connection_id, generation: generation}
        when length(generations) == @batch_size ->
          {connection_id, generation}

        _last ->
          nil
      end

    {{:ok, result}, %{state | recovery_cursor: cursor}}
  rescue
    exception ->
      reason = Exception.message(exception)

      Logger.warning("Could not reconcile acknowledged IRC ingestion claims",
        event: :irc_ingestion_claim_recovery_failed,
        reason: reason
      )

      {{:error, reason}, %{state | recovery_cursor: nil}}
  catch
    :exit, reason ->
      {{:error, reason}, %{state | recovery_cursor: nil}}
  end

  defp recover_generation(%{connection_id: connection_id, generation: generation}, result) do
    case WirekeeperTransport.acknowledged_through(connection_id, generation) do
      {:ok, :generation_gone} ->
        :ok = IrcIngestionEffect.release_generation(connection_id, generation)
        Map.update!(result, :released_generations, &(&1 + 1))

      {:ok, sequence} when sequence > 0 ->
        :ok = IrcIngestionEffect.release_through(connection_id, generation, sequence)
        Map.update!(result, :released_generations, &(&1 + 1))

      {:ok, 0} ->
        Map.update!(result, :retained_generations, &(&1 + 1))

      {:error, reason} ->
        result
        |> Map.update!(:retained_generations, &(&1 + 1))
        |> Map.update!(:errors, &[{connection_id, generation, reason} | &1])
    end
  end

  defp schedule_automatic_flush(%{flush_interval: :manual} = state), do: state
  defp schedule_automatic_flush(%{flush_interval: :disabled} = state), do: state
  defp schedule_automatic_flush(state), do: schedule_flush(state, state.flush_interval)

  defp schedule_flush(%{timer: nil} = state, interval) do
    %{state | timer: Process.send_after(self(), :flush, interval)}
  end

  defp schedule_flush(state, _interval), do: state

  defp schedule_recovery(%{recovery_interval: :disabled} = state), do: state

  defp schedule_recovery(%{recovery_timer: nil, recovery_cursor: cursor} = state) do
    interval = if is_nil(cursor), do: state.recovery_interval, else: 0
    %{state | recovery_timer: Process.send_after(self(), :recover, interval)}
  end

  defp schedule_recovery(state), do: state

  defp cancel_timer(%{timer: nil} = state), do: state

  defp cancel_timer(state) do
    Process.cancel_timer(state.timer)
    %{state | timer: nil}
  end
end
