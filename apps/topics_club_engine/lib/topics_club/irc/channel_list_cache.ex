defmodule TopicsClub.Irc.ChannelListCache do
  @moduledoc false

  use GenServer

  alias TopicsClub.Chat.ServerConnection

  @default_ttl_ms :timer.hours(1)
  @prune_interval_ms :timer.minutes(5)

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)

    if name do
      GenServer.start_link(__MODULE__, opts, name: name)
    else
      GenServer.start_link(__MODULE__, opts)
    end
  end

  def fetch(%ServerConnection{} = connection, callback, opts \\ [])
      when is_function(callback, 0) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:fetch, cache_key(connection), callback}, :infinity)
  end

  def cache_key(%ServerConnection{} = connection) do
    host =
      connection.host
      |> String.trim()
      |> String.trim_trailing(".")
      |> String.downcase()

    {host, connection.port, connection.use_tls}
  end

  @impl true
  def init(opts) do
    state = %{
      clock: Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end),
      entries: %{},
      pending: %{},
      refs: %{},
      task_supervisor:
        Keyword.get(opts, :task_supervisor, TopicsClub.Engine.RequestTaskSupervisor),
      ttl_ms: Keyword.get(opts, :ttl_ms, @default_ttl_ms)
    }

    schedule_prune()
    {:ok, state}
  end

  @impl true
  def handle_call({:fetch, key, callback}, from, state) do
    now = state.clock.()

    case Map.get(state.entries, key) do
      %{channels: channels, expires_at: expires_at} when expires_at > now ->
        {:reply, {:ok, channels}, state}

      _missing_or_expired ->
        state = %{state | entries: Map.delete(state.entries, key)}
        fetch_or_wait(state, key, callback, from)
    end
  end

  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    case Map.fetch(state.refs, ref) do
      {:ok, key} ->
        Process.demonitor(ref, [:flush])
        complete_fetch(state, key, result)

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.fetch(state.refs, ref) do
      {:ok, key} -> complete_fetch(state, key, {:error, :internal_error})
      :error -> {:noreply, state}
    end
  end

  def handle_info(:prune, state) do
    now = state.clock.()
    entries = Map.filter(state.entries, fn {_key, entry} -> entry.expires_at > now end)
    schedule_prune()
    {:noreply, %{state | entries: entries}}
  end

  defp fetch_or_wait(state, key, callback, from) do
    case Map.get(state.pending, key) do
      nil ->
        task = Task.Supervisor.async_nolink(state.task_supervisor, callback)
        pending = Map.put(state.pending, key, %{ref: task.ref, waiters: [from]})
        refs = Map.put(state.refs, task.ref, key)
        {:noreply, %{state | pending: pending, refs: refs}}

      pending ->
        pending = put_in(state.pending[key].waiters, [from | pending.waiters])
        {:noreply, %{state | pending: pending}}
    end
  end

  defp complete_fetch(state, key, result) do
    {pending, pending_by_key} = Map.pop(state.pending, key)

    if pending do
      Enum.each(pending.waiters, &GenServer.reply(&1, result))
    end

    entries =
      case result do
        {:ok, channels} when is_list(channels) ->
          Map.put(state.entries, key, %{
            channels: channels,
            expires_at: state.clock.() + state.ttl_ms
          })

        _error ->
          state.entries
      end

    refs = if pending, do: Map.delete(state.refs, pending.ref), else: state.refs
    {:noreply, %{state | entries: entries, pending: pending_by_key, refs: refs}}
  end

  defp schedule_prune do
    Process.send_after(self(), :prune, @prune_interval_ms)
  end
end
