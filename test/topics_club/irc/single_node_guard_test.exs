defmodule TopicsClub.Irc.SingleNodeGuardTest do
  use TopicsClub.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias TopicsClub.AccountsFixtures
  alias TopicsClub.Chat.Connections
  alias TopicsClub.Irc.ConnectionLock
  alias TopicsClub.Irc.SessionLocator
  alias TopicsClub.Irc.SessionSystemSupervisor
  alias TopicsClub.Irc.SessionSupervisor
  alias TopicsClub.Irc.SingleNodeGuard
  alias TopicsClub.IrcTestServer
  alias TopicsClub.Repo

  @tag :capture_log
  test "an unexpected visible node tears down every IRC session before the subsystem restarts" do
    server = start_supervised!({IrcTestServer, self()})
    user = AccountsFixtures.user_fixture()

    assert {:ok, connection} =
             Connections.create(user, %{
               "name" => "single-node guard",
               "host" => "127.0.0.1",
               "port" => IrcTestServer.port(server),
               "use_tls" => false,
               "nickname" => "mira"
             })

    assert {:ok, session_pid} = SessionSupervisor.start_session(connection)
    _ = :sys.get_state(SessionLocator.via(connection))
    session_ref = Process.monitor(session_pid)
    guard_pid = Process.whereis(SingleNodeGuard)
    guard_ref = Process.monitor(guard_pid)

    send(SingleNodeGuard, {:nodeup, :unsupported@host, [node_type: :visible]})

    assert_receive {:DOWN, ^guard_ref, :process, ^guard_pid,
                    {:multi_node_irc_not_supported, :unsupported@host}}

    assert_receive {:DOWN, ^session_ref, :process, ^session_pid, :shutdown}
    _ = :sys.get_state(SessionSystemSupervisor)

    refute Process.whereis(SingleNodeGuard) == guard_pid
    assert Process.whereis(SessionSupervisor)
    assert SessionLocator.whereis(connection) == nil
  end

  @tag :capture_log
  test "a real visible peer keeps IRC disabled without restarting the application" do
    assert Node.list(:visible) == []
    started_distribution? = start_distribution()

    on_exit(fn ->
      if started_distribution?, do: :net_kernel.stop()
    end)

    engine_supervisor = Process.whereis(TopicsClub.EngineSupervisor)
    session_system_supervisor = Process.whereis(SessionSystemSupervisor)
    old_guard = Process.whereis(SingleNodeGuard)
    old_session_supervisor = Process.whereis(SessionSupervisor)
    guard_ref = Process.monitor(old_guard)
    session_supervisor_ref = Process.monitor(old_session_supervisor)
    engine_ref = Process.monitor(engine_supervisor)
    task_supervisor = start_supervised!(Task.Supervisor)
    test_pid = self()
    lock_user_id = System.unique_integer([:positive])
    lock_connection_id = System.unique_integer([:positive])

    held_lock_task =
      unboxed_task(task_supervisor, fn ->
        ConnectionLock.run(lock_user_id, lock_connection_id, fn ->
          send(test_pid, {:topology_lock_acquired, self()})

          receive do
            :release_topology_lock -> :held_lock_done
          end
        end)
      end)

    assert_receive {:topology_lock_acquired, held_lock_pid}

    peer_name = :topics_club_single_node_guard_peer

    peer_pid =
      start_supervised!(%{
        id: peer_name,
        start:
          {:peer, :start_link, [%{name: peer_name, connection: :standard_io, shutdown: 5_000}]},
        restart: :temporary,
        shutdown: 10_000
      })

    peer_node = :peer.call(peer_pid, :erlang, :node, [])
    assert Node.connect(peer_node)

    assert_receive {:DOWN, ^guard_ref, :process, ^old_guard,
                    {:multi_node_irc_not_supported, ^peer_node}},
                   5_000

    assert_receive {:DOWN, ^session_supervisor_ref, :process, ^old_session_supervisor, :shutdown},
                   5_000

    _ = :sys.get_state(SessionSystemSupervisor)

    assert Process.whereis(TopicsClub.EngineSupervisor) == engine_supervisor
    assert Process.whereis(SessionSystemSupervisor) == session_system_supervisor
    assert peer_node in Node.list(:visible)
    refute Process.whereis(SingleNodeGuard) == old_guard
    refute Process.whereis(SessionSupervisor) == old_session_supervisor

    current_guard = Process.whereis(SingleNodeGuard)
    current_session_supervisor = Process.whereis(SessionSupervisor)
    current_guard_ref = Process.monitor(current_guard)
    current_session_supervisor_ref = Process.monitor(current_session_supervisor)

    assert {:error, :multi_node_irc_not_supported} =
             ConnectionLock.run(1, 1, fn -> flunk("lock callback must remain disabled") end)

    _ = :sys.get_state(current_guard)
    refute_receive {:DOWN, ^current_guard_ref, :process, ^current_guard, _reason}, 100
    refute_receive {:DOWN, ^engine_ref, :process, ^engine_supervisor, _reason}, 100

    assert :ok = stop_supervised(peer_name)

    assert_receive {:DOWN, ^current_guard_ref, :process, ^current_guard,
                    :single_node_topology_restored},
                   5_000

    assert_receive {:DOWN, ^current_session_supervisor_ref, :process, ^current_session_supervisor,
                    :shutdown},
                   5_000

    _ = :sys.get_state(SessionSystemSupervisor)

    assert Node.list(:visible) == []
    assert Process.whereis(TopicsClub.EngineSupervisor) == engine_supervisor

    second_lock_task =
      unboxed_task(task_supervisor, fn ->
        send(test_pid, {:topology_lock_attempting, self()})

        ConnectionLock.run(lock_user_id, lock_connection_id, fn ->
          send(test_pid, {:topology_lock_acquired_after_recovery, self()})
          :second_lock_done
        end)
      end)

    assert_receive {:topology_lock_attempting, second_lock_pid}
    refute_receive {:topology_lock_acquired_after_recovery, ^second_lock_pid}, 100

    send(held_lock_pid, :release_topology_lock)
    assert :held_lock_done = Task.await(held_lock_task)
    assert_receive {:topology_lock_acquired_after_recovery, ^second_lock_pid}
    assert :second_lock_done = Task.await(second_lock_task)
  end

  defp start_distribution do
    if Node.alive?() do
      false
    else
      assert {:ok, _pid} = :net_kernel.start([:topics_club_single_node_guard_origin, :shortnames])
      true
    end
  end

  defp unboxed_task(supervisor, callback) do
    Task.Supervisor.async_nolink(supervisor, fn ->
      :ok = Sandbox.checkout(Repo, sandbox: false)

      try do
        callback.()
      after
        :ok = Sandbox.checkin(Repo)
      end
    end)
  end
end
