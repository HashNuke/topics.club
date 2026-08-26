defmodule Ircpipe.Irc.SessionSupervisorTest do
  use ExUnit.Case, async: false

  alias Ircpipe.Chat.ServerConnection
  alias Ircpipe.Irc.Session
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

    assert {:via, Registry, {Ircpipe.Irc.SessionRegistry, registry_key}} =
             Session.via(connection)

    assert Registry.lookup(Ircpipe.Irc.SessionRegistry, registry_key) == [{pid, nil}]
    ref = Process.monitor(pid)

    assert :ok = SessionSupervisor.stop_session(connection)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    assert Registry.lookup(Ircpipe.Irc.SessionRegistry, registry_key) == []
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
  test "stops a transient replacement that starts after session name lookup" do
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
      stop_named_test_session(connection, 3)
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

    assert Session.whereis(connection) == nil
  end

  @tag :capture_log
  test "independent session failures do not exhaust the shared supervisor" do
    supervisor_pid = Process.whereis(SessionSupervisor)
    start_counter = start_supervised!({Agent, fn -> 0 end})

    Enum.each(1..4, fn _attempt ->
      unique_id = System.unique_integer([:positive])
      connection = %ServerConnection{id: unique_id, user_id: unique_id}

      {:ok, original_pid} =
        DynamicSupervisor.start_child(
          SessionSupervisor,
          {Ircpipe.RestartingIrcSession, {connection, self(), start_counter}}
        )

      assert_receive {:restarting_irc_session_started, ^original_pid}
      original_ref = Process.monitor(original_pid)
      GenServer.cast(original_pid, :crash)
      assert_receive {:DOWN, ^original_ref, :process, ^original_pid, :session_crashed}
      assert_receive {:restarting_irc_session_start_paused, restart_pid}
      send(restart_pid, {:continue_restarting_irc_session_start, connection.id})
      assert_receive {:restarting_irc_session_started, replacement_pid}
      replacement_ref = Process.monitor(replacement_pid)
      assert :ok = DynamicSupervisor.terminate_child(SessionSupervisor, replacement_pid)
      assert_receive {:DOWN, ^replacement_ref, :process, ^replacement_pid, :shutdown}
      assert Process.whereis(SessionSupervisor) == supervisor_pid
      Agent.update(start_counter, fn _count -> 0 end)
    end)
  end

  defp stop_named_test_session(_connection, 0), do: :ok

  defp stop_named_test_session(connection, attempts_left) do
    case Session.whereis(connection) do
      pid when is_pid(pid) ->
        _ = DynamicSupervisor.terminate_child(SessionSupervisor, pid)
        stop_named_test_session(connection, attempts_left - 1)

      nil ->
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
