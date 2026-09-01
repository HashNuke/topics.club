defmodule TopicsClub.Irc.IngestionClaimReleaser do
  @moduledoc false

  use GenServer

  require Logger

  alias TopicsClub.Chat.IrcIngestionEffect

  @default_flush_interval 25
  @retry_interval 1_000
  @batch_size 100

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
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

  @impl true
  def init(_opts) do
    flush_interval =
      Application.get_env(
        :topics_club_engine,
        :ingestion_claim_release_interval,
        @default_flush_interval
      )

    {:ok, %{pending: MapSet.new(), timer: nil, flush_interval: flush_interval}}
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

  @impl true
  def handle_info(:flush, state) do
    {_result, state} = flush_pending(%{state | timer: nil})
    {:noreply, state}
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

  defp schedule_automatic_flush(%{flush_interval: :manual} = state), do: state
  defp schedule_automatic_flush(%{flush_interval: :disabled} = state), do: state
  defp schedule_automatic_flush(state), do: schedule_flush(state, state.flush_interval)

  defp schedule_flush(%{timer: nil} = state, interval) do
    %{state | timer: Process.send_after(self(), :flush, interval)}
  end

  defp schedule_flush(state, _interval), do: state

  defp cancel_timer(%{timer: nil} = state), do: state

  defp cancel_timer(state) do
    Process.cancel_timer(state.timer)
    %{state | timer: nil}
  end
end
