defmodule TopicsClubWeb.EngineNodeConnector do
  @moduledoc false

  use GenServer

  require Logger

  @retry_min 500
  @retry_max 30_000

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def status(name \\ __MODULE__), do: GenServer.call(name, :status)

  @impl true
  def init(opts) do
    engine_node = Keyword.fetch!(opts, :engine_node)
    retry_min = Keyword.get(opts, :retry_min, @retry_min)
    retry_max = Keyword.get(opts, :retry_max, @retry_max)

    true = is_atom(engine_node)
    true = is_integer(retry_min) and retry_min > 0
    true = is_integer(retry_max) and retry_max >= retry_min
    :ok = :net_kernel.monitor_nodes(true, node_type: :visible)

    state = %{
      engine_node: engine_node,
      retry_attempt: 0,
      retry_delay: retry_min,
      retry_min: retry_min,
      retry_max: retry_max,
      status: :connecting,
      timer: nil
    }

    send(self(), :connect)
    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply,
     %{
       connected?: state.status == :connected,
       engine_node: state.engine_node,
       retry_attempt: state.retry_attempt,
       status: state.status
     }, state}
  end

  @impl true
  def handle_info(:connect, state) do
    state = %{state | timer: nil}

    if connected?(state.engine_node) or Node.connect(state.engine_node) == true do
      {:noreply, mark_connected(state)}
    else
      {:noreply, schedule_retry(state)}
    end
  end

  def handle_info({:nodeup, engine_node, _info}, %{engine_node: engine_node} = state) do
    {:noreply, mark_connected(state)}
  end

  def handle_info({:nodedown, engine_node, _info}, %{engine_node: engine_node} = state) do
    Logger.warning("Engine node disconnected: #{inspect(engine_node)}")

    :telemetry.execute(
      [:topics_club, :engine_node, :connection],
      %{system_time: System.system_time()},
      %{engine_node: engine_node, status: :disconnected}
    )

    {:noreply, schedule_retry(%{state | status: :disconnected, retry_delay: state.retry_min})}
  end

  def handle_info({_event, _node, _info}, state), do: {:noreply, state}

  defp connected?(engine_node), do: engine_node in Node.list(:visible)

  defp mark_connected(state) do
    cancel_timer(state.timer)

    if state.status != :connected do
      Logger.info("Connected to engine node #{inspect(state.engine_node)}")

      :telemetry.execute(
        [:topics_club, :engine_node, :connection],
        %{system_time: System.system_time()},
        %{engine_node: state.engine_node, status: :connected}
      )
    end

    %{state | status: :connected, retry_attempt: 0, retry_delay: state.retry_min, timer: nil}
  end

  defp schedule_retry(%{timer: timer} = state) when is_reference(timer), do: state

  defp schedule_retry(state) do
    timer = Process.send_after(self(), :connect, state.retry_delay)

    :telemetry.execute(
      [:topics_club, :engine_node, :reconnect],
      %{delay: state.retry_delay},
      %{attempt: state.retry_attempt + 1, engine_node: state.engine_node}
    )

    %{
      state
      | status: :disconnected,
        retry_attempt: state.retry_attempt + 1,
        retry_delay: min(state.retry_delay * 2, state.retry_max),
        timer: timer
    }
  end

  defp cancel_timer(nil), do: :ok

  defp cancel_timer(timer) do
    _result = Process.cancel_timer(timer)
    :ok
  end
end
