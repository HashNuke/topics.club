defmodule TopicsClub.Engine.OperationLock do
  @moduledoc false

  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def run(user_id, connection_id, callback)
      when is_integer(user_id) and is_integer(connection_id) and is_function(callback, 0) do
    key = {user_id, connection_id}
    :ok = GenServer.call(__MODULE__, {:acquire, key}, :infinity)

    try do
      callback.()
    after
      release(key)
    end
  end

  @impl true
  def init(_opts), do: {:ok, %{locks: %{}, monitors: %{}}}

  @impl true
  def handle_call({:acquire, key}, from, state) do
    owner = elem(from, 0)

    case Map.get(state.locks, key) do
      nil ->
        owner_ref = Process.monitor(owner)
        lock = %{owner: owner, owner_ref: owner_ref, depth: 1, waiters: :queue.new()}

        {:reply, :ok,
         state
         |> put_lock(key, lock)
         |> put_monitor(owner_ref, {key, :owner})}

      %{owner: ^owner} = lock ->
        {:reply, :ok, put_lock(state, key, %{lock | depth: lock.depth + 1})}

      lock ->
        waiter_ref = Process.monitor(owner)
        waiter = %{from: from, pid: owner, ref: waiter_ref}
        lock = %{lock | waiters: :queue.in(waiter, lock.waiters)}

        {:noreply,
         state
         |> put_lock(key, lock)
         |> put_monitor(waiter_ref, {key, :waiter})}
    end
  end

  def handle_call({:release, key}, {owner, _tag}, state) do
    case Map.get(state.locks, key) do
      %{owner: ^owner, depth: depth} = lock when depth > 1 ->
        {:reply, :ok, put_lock(state, key, %{lock | depth: depth - 1})}

      %{owner: ^owner} = lock ->
        Process.demonitor(lock.owner_ref, [:flush])
        state = delete_monitor(state, lock.owner_ref)
        {:reply, :ok, handoff(state, key, lock.waiters)}

      _missing_or_restarted_lock ->
        {:reply, {:error, :not_owner}, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, _monitors} ->
        {:noreply, state}

      {{key, :owner}, monitors} ->
        lock = Map.fetch!(state.locks, key)
        {:noreply, handoff(%{state | monitors: monitors}, key, lock.waiters)}

      {{key, :waiter}, monitors} ->
        lock = Map.fetch!(state.locks, key)

        waiters =
          lock.waiters
          |> :queue.to_list()
          |> Enum.reject(&(&1.ref == ref))
          |> :queue.from_list()

        {:noreply, put_lock(%{state | monitors: monitors}, key, %{lock | waiters: waiters})}
    end
  end

  defp handoff(state, key, waiters) do
    case :queue.out(waiters) do
      {{:value, waiter}, remaining} ->
        GenServer.reply(waiter.from, :ok)

        lock = %{
          owner: waiter.pid,
          owner_ref: waiter.ref,
          depth: 1,
          waiters: remaining
        }

        state
        |> put_lock(key, lock)
        |> put_monitor(waiter.ref, {key, :owner})

      {:empty, _waiters} ->
        %{state | locks: Map.delete(state.locks, key)}
    end
  end

  defp put_lock(state, key, lock), do: %{state | locks: Map.put(state.locks, key, lock)}

  defp put_monitor(state, ref, owner),
    do: %{state | monitors: Map.put(state.monitors, ref, owner)}

  defp delete_monitor(state, ref), do: %{state | monitors: Map.delete(state.monitors, ref)}

  defp release(key) do
    case GenServer.call(__MODULE__, {:release, key}) do
      :ok -> :ok
      {:error, :not_owner} -> :ok
    end
  catch
    :exit, {:noproc, _call} -> :ok
  end
end
