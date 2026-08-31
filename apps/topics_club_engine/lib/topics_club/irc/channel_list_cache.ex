defmodule TopicsClub.Irc.ChannelListCache do
  @moduledoc false

  use GenServer

  alias TopicsClub.Chat.ServerConnection

  @default_ttl_ms :timer.hours(24)
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

  def invalidate(%ServerConnection{} = connection, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:invalidate, cache_key(connection)})
  end

  def cache_key(%ServerConnection{} = connection) do
    host =
      connection.host
      |> String.trim()
      |> String.trim_trailing(".")
      |> String.downcase()

    {
      connection.user_id,
      connection.id,
      host,
      connection.port,
      connection.use_tls,
      normalize_identity(connection.nickname),
      normalize_identity(connection.sasl_username)
    }
  end

  @impl true
  def init(opts) do
    state = %{
      clock: Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end),
      entries: %{},
      generations: %{},
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
        generation = Map.get(state.generations, key, 0)
        fetch_or_wait(state, key, generation, callback, from)
    end
  end

  def handle_call({:invalidate, key}, _from, state) do
    generations = Map.update(state.generations, key, 1, &(&1 + 1))

    {:reply, :ok, %{state | entries: Map.delete(state.entries, key), generations: generations}}
  end

  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    case Map.fetch(state.refs, ref) do
      {:ok, pending_key} ->
        Process.demonitor(ref, [:flush])
        complete_fetch(state, pending_key, result)

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.fetch(state.refs, ref) do
      {:ok, pending_key} -> complete_fetch(state, pending_key, {:error, :internal_error})
      :error -> {:noreply, state}
    end
  end

  def handle_info(:prune, state) do
    now = state.clock.()
    entries = Map.filter(state.entries, fn {_key, entry} -> entry.expires_at > now end)
    schedule_prune()
    {:noreply, %{state | entries: entries}}
  end

  defp fetch_or_wait(state, key, generation, callback, from) do
    pending_key = {key, generation}

    case Map.get(state.pending, pending_key) do
      nil ->
        task = Task.Supervisor.async_nolink(state.task_supervisor, callback)
        pending = Map.put(state.pending, pending_key, %{ref: task.ref, waiters: [from]})
        refs = Map.put(state.refs, task.ref, pending_key)
        {:noreply, %{state | pending: pending, refs: refs}}

      pending ->
        pending = put_in(state.pending[pending_key].waiters, [from | pending.waiters])
        {:noreply, %{state | pending: pending}}
    end
  end

  defp complete_fetch(state, {key, generation} = pending_key, result) do
    {pending, pending_by_key} = Map.pop(state.pending, pending_key)

    if pending do
      Enum.each(pending.waiters, &GenServer.reply(&1, result))
    end

    entries =
      case {result, Map.get(state.generations, key, 0)} do
        {{:ok, channels}, ^generation} when is_list(channels) ->
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

  defp normalize_identity(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_identity(_value), do: nil
end
