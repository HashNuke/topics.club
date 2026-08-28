defmodule IrcpipeWeb.EngineRestorer do
  @moduledoc false

  use GenServer

  alias Ircpipe.Accounts.User
  alias Ircpipe.Chat.ServerConnection
  alias Ircpipe.EngineClient

  @max_concurrency 8

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def restore(server \\ __MODULE__, %User{} = user, connections) when is_list(connections) do
    desired_connection_ids =
      connections
      |> Enum.filter(&ServerConnection.connect_desired?/1)
      |> Enum.map(& &1.id)

    GenServer.call(server, {:restore, user.id, desired_connection_ids})
  end

  @doc false
  def await_idle(timeout \\ 5_000), do: await_idle(__MODULE__, timeout)

  @doc false
  def await_idle(server, timeout), do: GenServer.call(server, :await_idle, timeout)

  @impl true
  def init(opts) do
    {:ok,
     %{
       task_supervisor:
         Keyword.get(opts, :task_supervisor, IrcpipeWeb.EngineRestoreTaskSupervisor),
       pending: :queue.new(),
       scheduled: MapSet.new(),
       running: %{},
       idle_waiters: []
     }}
  end

  @impl true
  def handle_call({:restore, user_id, connection_ids}, _from, state) do
    state =
      Enum.reduce(connection_ids, state, fn connection_id, acc ->
        enqueue(acc, {user_id, connection_id})
      end)

    {:reply, :ok, state |> dispatch() |> reply_idle_waiters()}
  end

  @impl true
  def handle_call(:await_idle, from, state) do
    if idle?(state) do
      {:reply, :ok, state}
    else
      {:noreply, %{state | idle_waiters: [from | state.idle_waiters]}}
    end
  end

  @impl true
  def handle_info({reference, _result}, state) when is_reference(reference) do
    Process.demonitor(reference, [:flush])
    {:noreply, state |> complete(reference) |> dispatch() |> reply_idle_waiters()}
  end

  def handle_info({:DOWN, reference, :process, _pid, _reason}, state) do
    {:noreply, state |> complete(reference) |> dispatch() |> reply_idle_waiters()}
  end

  defp enqueue(state, key) do
    if MapSet.member?(state.scheduled, key) do
      state
    else
      %{
        state
        | pending: :queue.in(key, state.pending),
          scheduled: MapSet.put(state.scheduled, key)
      }
    end
  end

  defp dispatch(%{running: running} = state) when map_size(running) >= @max_concurrency,
    do: state

  defp dispatch(state) do
    case :queue.out(state.pending) do
      {{:value, {user_id, connection_id} = key}, pending} ->
        task =
          Task.Supervisor.async_nolink(state.task_supervisor, fn ->
            EngineClient.ensure_connection(user_id, connection_id, intent: "restore")
          end)

        state
        |> Map.put(:pending, pending)
        |> put_in([:running, task.ref], key)
        |> dispatch()

      {:empty, _pending} ->
        state
    end
  end

  defp complete(state, reference) do
    case Map.pop(state.running, reference) do
      {nil, _running} ->
        state

      {key, running} ->
        %{state | running: running, scheduled: MapSet.delete(state.scheduled, key)}
    end
  end

  defp reply_idle_waiters(state) do
    if idle?(state) do
      Enum.each(state.idle_waiters, &GenServer.reply(&1, :ok))
      %{state | idle_waiters: []}
    else
      state
    end
  end

  defp idle?(%{running: running, pending: pending}) do
    map_size(running) == 0 and :queue.is_empty(pending)
  end
end
