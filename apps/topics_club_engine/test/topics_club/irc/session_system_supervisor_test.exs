defmodule TopicsClub.Irc.SessionSystemSupervisorTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias TopicsClub.Irc.Bouncer
  alias TopicsClub.Irc.ConnectionOperationLock
  alias TopicsClub.Irc.SessionSupervisor
  alias TopicsClub.Irc.SessionSystemSupervisor

  for child_name <- [Bouncer, ConnectionOperationLock] do
    test "a #{inspect(child_name)} crash does not restart live sessions" do
      probe = start_session_probe()
      probe_ref = Process.monitor(probe)
      subsystem = Process.whereis(SessionSystemSupervisor)

      restart_direct_child(TopicsClub.EngineSupervisor, unquote(child_name))

      refute_receive {:DOWN, ^probe_ref, :process, ^probe, _reason}, 100
      assert Agent.get(probe, & &1) == :connected
      assert Process.whereis(SessionSystemSupervisor) == subsystem
    end
  end

  for registry <- [TopicsClub.Irc.ClientRegistry, TopicsClub.Irc.SessionRegistry] do
    test "a #{inspect(registry)} crash restarts the registration-consistent session group" do
      capture_log(fn -> exercise_registry_restart(unquote(registry)) end)
    end
  end

  defp exercise_registry_restart(registry) do
    probe = start_session_probe()
    probe_ref = Process.monitor(probe)
    session_supervisor = Process.whereis(SessionSupervisor)
    session_supervisor_ref = Process.monitor(session_supervisor)
    bouncer = Process.whereis(Bouncer)
    operation_lock = Process.whereis(ConnectionOperationLock)

    restart_direct_child(SessionSystemSupervisor, registry, :graceful)

    assert_receive {:DOWN, ^probe_ref, :process, ^probe, _reason}, 1_000

    assert_receive {:DOWN, ^session_supervisor_ref, :process, ^session_supervisor, _reason},
                   1_000

    replacement =
      await_direct_child_replacement(
        SessionSystemSupervisor,
        SessionSupervisor,
        session_supervisor
      )

    _ = :sys.get_state(replacement)
    assert Process.whereis(Bouncer) == bouncer
    assert Process.whereis(ConnectionOperationLock) == operation_lock
    assert Process.whereis(SessionSystemSupervisor)
    assert_bouncer_monitors(replacement)
  end

  defp start_session_probe do
    session_supervisor = await_named_process(SessionSupervisor)

    assert {:ok, probe} =
             DynamicSupervisor.start_child(session_supervisor, {Agent, fn -> :connected end})

    on_exit(fn ->
      try do
        _result = DynamicSupervisor.terminate_child(SessionSupervisor, probe)
      catch
        :exit, _reason -> :ok
      end
    end)

    probe
  end

  defp restart_direct_child(supervisor, child_id, stop_mode \\ :kill) do
    child = direct_child_pid(supervisor, child_id)
    assert is_pid(child)
    child_ref = Process.monitor(child)

    expected_reason =
      case stop_mode do
        :kill ->
          Process.exit(child, :kill)
          :killed

        :graceful ->
          :ok = GenServer.stop(child, :registry_crash)
          :registry_crash
      end

    assert_receive {:DOWN, ^child_ref, :process, ^child, ^expected_reason}, 1_000

    await_direct_child_replacement(supervisor, child_id, child)
  end

  defp await_named_process(name, attempts \\ 5_000)

  defp await_named_process(name, attempts) when attempts > 0 do
    case Process.whereis(name) do
      process when is_pid(process) ->
        if stable?(name, process), do: process, else: await_process_after(name, attempts)

      nil ->
        await_process_after(name, attempts)
    end
  end

  defp await_named_process(name, 0), do: flunk("#{inspect(name)} is unavailable")

  defp await_process_after(name, attempts) do
    receive do
    after
      1 -> await_named_process(name, attempts - 1)
    end
  end

  defp stable?(name, process) do
    _state = :sys.get_state(process)
    Process.whereis(name) == process
  catch
    :exit, _reason -> false
  end

  defp direct_child_pid(supervisor, child_id) do
    supervisor
    |> Supervisor.which_children()
    |> Enum.find_value(fn
      {^child_id, pid, _type, _modules} -> pid
      _child -> nil
    end)
  end

  defp await_direct_child_replacement(supervisor, child_id, previous, attempts \\ 5_000)

  defp await_direct_child_replacement(supervisor, child_id, previous, attempts)
       when attempts > 0 do
    case direct_child_pid(supervisor, child_id) do
      replacement when is_pid(replacement) and replacement != previous ->
        replacement

      _not_restarted ->
        receive do
        after
          1 ->
            await_direct_child_replacement(supervisor, child_id, previous, attempts - 1)
        end
    end
  end

  defp await_direct_child_replacement(_supervisor, child_id, _previous, 0) do
    flunk("#{inspect(child_id)} did not restart")
  end

  defp assert_bouncer_monitors(session_supervisor, attempts \\ 1_000)

  defp assert_bouncer_monitors(session_supervisor, attempts) when attempts > 0 do
    case :sys.get_state(Bouncer) do
      %{session_supervisor: ^session_supervisor} ->
        :ok

      _not_monitoring ->
        receive do
        after
          1 -> assert_bouncer_monitors(session_supervisor, attempts - 1)
        end
    end
  end

  defp assert_bouncer_monitors(session_supervisor, 0) do
    flunk("bouncer did not monitor replacement session supervisor #{inspect(session_supervisor)}")
  end
end
