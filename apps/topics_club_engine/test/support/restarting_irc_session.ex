defmodule TopicsClub.RestartingIrcSession do
  use GenServer

  alias TopicsClub.Irc.SessionLocator

  def child_spec({connection, test_pid, start_counter}) do
    %{
      id: {__MODULE__, connection.user_id, connection.id},
      start: {__MODULE__, :start_link, [{connection, test_pid, start_counter}]},
      restart: :transient
    }
  end

  def start_link({connection, test_pid, start_counter}) do
    start_number = Agent.get_and_update(start_counter, &{&1 + 1, &1 + 1})

    if start_number > 1 do
      test_ref = Process.monitor(test_pid)
      send(test_pid, {:restarting_irc_session_start_paused, self()})

      receive do
        {:continue_restarting_irc_session_start, connection_id}
        when connection_id == connection.id ->
          Process.demonitor(test_ref, [:flush])

        {:DOWN, ^test_ref, :process, ^test_pid, _reason} ->
          :ok
      end
    end

    GenServer.start_link(__MODULE__, {connection, test_pid}, name: SessionLocator.via(connection))
  end

  @impl true
  def init({_connection, test_pid} = state) do
    send(test_pid, {:restarting_irc_session_started, self()})
    {:ok, state}
  end

  @impl true
  def handle_call({:quit, _reason}, _from, state) do
    {:stop, :normal, :ok, state}
  end

  @impl true
  def handle_cast(:crash, state) do
    {:stop, :session_crashed, state}
  end

  @impl true
  def terminate(:normal, {_connection, test_pid}) do
    send(test_pid, {:restarting_irc_session_stopped, self()})
    :ok
  end

  def terminate(_reason, _state), do: :ok
end
