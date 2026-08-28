defmodule TopicsClub.Engine.MarkerTest do
  use TopicsClub.DataCase, async: false

  alias TopicsClub.AccountsFixtures
  alias TopicsClub.Chat.Connections
  alias TopicsClub.Engine.Marker
  alias TopicsClub.EngineClient.Discovery
  alias TopicsClub.Irc.ConnectionLock
  alias TopicsClub.Irc.SessionLocator
  alias TopicsClub.Irc.SessionSupervisor
  alias TopicsClub.IrcTestServer

  test "the global marker rejects a second marker visible in the connected cluster" do
    assert {:ok, marker} = Discovery.whereis()
    assert %{status: :owner, owner_node: owner_node, started_at: started_at} = Marker.status()
    assert owner_node == Atom.to_string(node())
    assert {:ok, _timestamp, 0} = DateTime.from_iso8601(started_at)
    assert {:error, {:already_started, ^marker}} = Marker.start_link([])
  end

  test "a visible duplicate marker stops engine supervision before later children start" do
    test_pid = self()
    previous_trap_exit = Process.flag(:trap_exit, true)
    on_exit(fn -> Process.flag(:trap_exit, previous_trap_exit) end)

    children = [
      {Marker, []},
      Supervisor.child_spec(
        {Task, fn -> send(test_pid, :duplicate_engine_started_later_child) end},
        id: :duplicate_engine_later_child
      )
    ]

    assert {:error,
            {:shutdown, {:failed_to_start_child, Marker, {:already_started, existing_marker}}}} =
             Supervisor.start_link(children, strategy: :one_for_one)

    assert is_pid(existing_marker)
    refute_receive :duplicate_engine_started_later_child
  end

  test "a connected non-engine node leaves IRC sessions and connection locks operational" do
    server = start_supervised!({IrcTestServer, self()})
    user = AccountsFixtures.user_fixture()

    assert {:ok, connection} =
             Connections.create(user, %{
               "name" => "distributed marker",
               "host" => "127.0.0.1",
               "port" => IrcTestServer.port(server),
               "use_tls" => false,
               "nickname" => "mira"
             })

    assert {:ok, session_pid} = SessionSupervisor.start_session(connection)
    _ = :sys.get_state(SessionLocator.via(connection))
    session_ref = Process.monitor(session_pid)
    marker_pid = elem(Discovery.whereis(), 1)
    marker_ref = Process.monitor(marker_pid)

    started_distribution? = start_distribution()

    on_exit(fn ->
      if started_distribution?, do: :net_kernel.stop()
    end)

    peer_name = :topics_club_web_peer

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
    assert peer_node in Node.list(:visible)
    assert :lock_available = ConnectionLock.run(connection, fn -> :lock_available end)
    _ = :sys.get_state(SessionLocator.via(connection))

    refute_receive {:DOWN, ^session_ref, :process, ^session_pid, _reason}, 100
    refute_receive {:DOWN, ^marker_ref, :process, ^marker_pid, _reason}, 100

    assert :ok = stop_supervised(peer_name)
    assert :ok = SessionSupervisor.stop_session(connection)
    assert_receive {:DOWN, ^session_ref, :process, ^session_pid, :normal}
  end

  defp start_distribution do
    if Node.alive?() do
      false
    else
      assert {:ok, _pid} = :net_kernel.start([:topics_club_engine_test, :shortnames])
      true
    end
  end
end
