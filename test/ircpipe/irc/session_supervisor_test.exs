defmodule Ircpipe.Irc.SessionSupervisorTest do
  use ExUnit.Case, async: false

  alias Ircpipe.Chat.ServerConnection
  alias Ircpipe.Irc.SessionSupervisor

  setup do
    previous_pause = Application.get_env(:ircpipe, :pause_session_stop_after_lookup)

    on_exit(fn ->
      if is_nil(previous_pause) do
        Application.delete_env(:ircpipe, :pause_session_stop_after_lookup)
      else
        Application.put_env(:ircpipe, :pause_session_stop_after_lookup, previous_pause)
      end
    end)

    :ok
  end

  test "stopping an already-closed IRC client succeeds" do
    unique_id = System.unique_integer([:positive])
    connection = %ServerConnection{id: unique_id, user_id: unique_id}

    pid = start_supervised!({Ircpipe.ClosedIrcSession, connection})
    ref = Process.monitor(pid)

    assert :ok = SessionSupervisor.stop_session(connection)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
  end

  @tag :capture_log
  test "an abnormal session exit is not reported as a successful stop" do
    unique_id = System.unique_integer([:positive])
    connection = %ServerConnection{id: unique_id, user_id: unique_id}

    pid = start_supervised!({Ircpipe.CrashingIrcSession, connection})
    ref = Process.monitor(pid)

    assert {:error, {:session_exit, _reason}} = SessionSupervisor.stop_session(connection)
    assert_receive {:DOWN, ^ref, :process, ^pid, :quit_failed}
  end

  @tag :capture_log
  test "stops a transient replacement that starts after registry lookup" do
    unique_id = System.unique_integer([:positive])
    connection = %ServerConnection{id: unique_id, user_id: unique_id}
    test_pid = self()
    start_counter = start_supervised!({Agent, fn -> 0 end})

    {:ok, original_pid} =
      DynamicSupervisor.start_child(
        SessionSupervisor,
        {Ircpipe.RestartingIrcSession, {connection, test_pid, start_counter}}
      )

    on_exit(fn ->
      Application.delete_env(:ircpipe, :pause_session_stop_after_lookup)
      _ = terminate_test_session(original_pid)
      stop_registered_test_session(connection, 3)
    end)

    assert_receive {:restarting_irc_session_started, ^original_pid}
    Application.put_env(:ircpipe, :pause_session_stop_after_lookup, self())
    task_supervisor = start_supervised!(Task.Supervisor)

    stop_task =
      Task.Supervisor.async_nolink(task_supervisor, fn ->
        SessionSupervisor.stop_session(connection)
      end)

    assert_receive {:session_stop_paused, stop_pid, ^original_pid}
    original_ref = Process.monitor(original_pid)
    GenServer.cast(original_pid, :crash)
    assert_receive {:DOWN, ^original_ref, :process, ^original_pid, :session_crashed}
    assert_receive {:restarting_irc_session_start_paused, supervisor_pid}, 1_000

    Application.delete_env(:ircpipe, :pause_session_stop_after_lookup)
    send(stop_pid, {:continue_session_stop, original_pid})
    refute Task.yield(stop_task, 100)
    send(supervisor_pid, {:continue_restarting_irc_session_start, connection.id})

    assert_receive {:restarting_irc_session_started, replacement_pid}
    assert :ok = Task.await(stop_task)
    assert_receive {:restarting_irc_session_stopped, ^replacement_pid}

    assert Registry.lookup(Ircpipe.Irc.SessionRegistry, {connection.user_id, connection.id}) == []
  end

  defp stop_registered_test_session(_connection, 0), do: :ok

  defp stop_registered_test_session(connection, attempts_left) do
    case Registry.lookup(Ircpipe.Irc.SessionRegistry, {connection.user_id, connection.id}) do
      [{pid, _value}] ->
        _ = DynamicSupervisor.terminate_child(SessionSupervisor, pid)
        stop_registered_test_session(connection, attempts_left - 1)

      [] ->
        :ok
    end
  catch
    :exit, _reason -> :ok
  end

  defp terminate_test_session(pid) do
    DynamicSupervisor.terminate_child(SessionSupervisor, pid)
  catch
    :exit, _reason -> :ok
  end
end
