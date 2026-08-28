defmodule TopicsClub.DistributedRuntimeTest do
  use TopicsClub.DataCase, async: false

  alias TopicsClub.AccountsFixtures
  alias TopicsClub.Chat.Connections
  alias TopicsClub.Chat.DirectMessageIngestion
  alias TopicsClub.Chat.MessageHistory
  alias TopicsClub.EngineClient
  alias TopicsClub.EngineClient.Discovery
  alias TopicsClub.EngineClient.RpcAdapter
  alias TopicsClub.Engine.Marker
  alias TopicsClub.Irc.SessionLocator
  alias TopicsClub.IrcTestServer

  @tag :capture_log
  test "a restarted gateway drives the real engine operation set without restarting its session" do
    started_distribution? = start_distribution()
    on_exit(fn -> if started_distribution?, do: :net_kernel.stop() end)

    server = start_supervised!({IrcTestServer, self()})
    user = AccountsFixtures.user_fixture()

    assert {:ok, connection} =
             Connections.create(user, %{
               "name" => "distributed runtime",
               "host" => "localhost",
               "port" => IrcTestServer.port(server),
               "use_tls" => false,
               "nickname" => "topics_club"
             })

    assert {:ok, connection} =
             connection
             |> Ecto.Changeset.change(desired_state: "paused")
             |> Repo.update()

    :ok = Phoenix.PubSub.subscribe(TopicsClub.PubSub, "user:#{user.id}")

    {first_peer, first_peer_node} =
      start_gateway_peer(:distributed_gateway_one, :distributed_gateway_one)

    marker_pid = elem(Discovery.whereis(), 1)

    assert {:error, {:already_started, ^marker_pid}} =
             :peer.call(first_peer, Marker, :start_link, [[]])

    assert DynamicSupervisor.count_children(TopicsClub.Irc.SessionSupervisor).active == 0

    assert {:ok, %{protocol_version: 1}} = remote(first_peer, :protocol_info, [[]])

    assert {:ok, %{statuses: [%{connection_id: connection_id, status: "disconnected"}]}} =
             remote(first_peer, :connection_statuses, [user.id, [connection.id], []])

    assert connection_id == connection.id

    assert {:ok, %{membership: membership, status: join_status}} =
             remote(first_peer, :join_channel, [user.id, connection.id, "#pipe", []])

    assert join_status in ["queued", "sent"]
    assert_receive {:irc_server_line, "NICK topics_club"}, 1_000
    assert_receive {:irc_server_line, "USER topics_club 0 * topics_club"}, 1_000
    assert_receive {:irc_server_line, "JOIN #pipe"}, 1_000
    assert_receive {:presence_sync, %{buffer_id: "channel:" <> _membership_id}}, 1_000

    assert {:ok, %{connection_info: %{registered?: true, casemapping: :rfc1459}}} =
             remote(first_peer, :connection_info, [user.id, connection.id, []])

    assert {:ok, %{statuses: [%{status: "connected"}]}} =
             remote(first_peer, :connection_statuses, [user.id, [connection.id], []])

    assert {:ok, %{message: %{body: "hello across nodes"}}} =
             remote(first_peer, :send_channel_message, [
               user.id,
               connection.id,
               membership.id,
               "hello across nodes",
               []
             ])

    assert_receive {:irc_server_line, "PRIVMSG #pipe :hello across nodes"}, 1_000

    assert {:ok, %{channels: [%{channel: "#elixir"} | _channels]}} =
             remote(first_peer, :list_channels, [user.id, connection.id, []])

    assert_receive {:irc_server_line, "LIST"}, 1_000

    assert {:ok, %{result: %{command: "nick", command_id: "distributed-command-1"}}} =
             remote(first_peer, :execute_command, [
               user.id,
               connection.id,
               "NICK topics_club_",
               "distributed-command-1",
               "server:#{connection.id}",
               []
             ])

    assert_receive {:irc_server_line, "NICK topics_club_"}, 1_000

    assert {:ok, %{thread: thread}} =
             DirectMessageIngestion.record(
               connection,
               "akash",
               "akash",
               "hello",
               "message",
               %{direction: "outgoing"}
             )

    assert {:ok, %{thread: %{id: thread_id}, message: %{body: "private across nodes"}}} =
             remote(first_peer, :send_direct_message, [
               user.id,
               connection.id,
               thread.id,
               "private across nodes",
               []
             ])

    assert thread_id == thread.id
    assert_receive {:irc_server_line, "PRIVMSG akash :private across nodes"}, 1_000

    session_pid = SessionLocator.whereis(connection)
    assert is_pid(session_pid)
    session_ref = Process.monitor(session_pid)
    marker_ref = Process.monitor(marker_pid)
    hosted_server_supervisor = Process.whereis(TopicsClub.Irc.HostedServerSupervisor)
    assert is_pid(hosted_server_supervisor)
    hosted_server_ref = Process.monitor(hosted_server_supervisor)

    assert :ok = stop_supervised(:distributed_gateway_one)
    refute_receive {:DOWN, ^session_ref, :process, ^session_pid, _reason}, 100
    refute_receive {:DOWN, ^marker_ref, :process, ^marker_pid, _reason}, 100

    refute_receive {:DOWN, ^hosted_server_ref, :process, ^hosted_server_supervisor, _reason},
                   100

    refute first_peer_node in Node.list(:visible)

    assert :ok = IrcTestServer.broadcast(server, "#pipe", "akash", "while gateway was down")
    assert_receive {:buffer_message, %{body: "while gateway was down"}}, 1_000

    assert Enum.any?(MessageHistory.list_messages(user, membership.id), fn message ->
             message.body == "while gateway was down"
           end)

    {second_peer, _second_peer_node} =
      start_gateway_peer(:distributed_gateway_two, :distributed_gateway_two)

    assert {:ok, %{connection_info: %{registered?: true}}} =
             remote(second_peer, :connection_info, [user.id, connection.id, []])

    assert {:ok, %{membership_id: membership_id, status: "sent"}} =
             remote(second_peer, :part_channel, [user.id, connection.id, membership.id, []])

    assert membership_id == membership.id
    assert_receive {:irc_server_line, "PART #pipe" <> _reason}, 1_000

    assert {:ok, %{connection: %{desired_state: "paused"}, status: "disconnected"}} =
             remote(second_peer, :disconnect_connection, [user.id, connection.id, []])

    assert_receive {:irc_server_line, "QUIT leaving"}, 1_000
    assert_receive {:DOWN, ^session_ref, :process, ^session_pid, :normal}

    assert {:ok, %{connection_id: deleted_id, deleted: true}} =
             remote(second_peer, :delete_connection, [user.id, connection.id, []])

    assert deleted_id == connection.id
  end

  defp start_distribution do
    if Node.alive?() do
      false
    else
      assert {:ok, _pid} = :net_kernel.start([:distributed_engine_test, :shortnames])
      true
    end
  end

  defp start_gateway_peer(id, name) do
    peer =
      start_supervised!(%{
        id: id,
        start:
          {:peer, :start_link,
           [
             %{
               name: name,
               connection: :standard_io,
               shutdown: 5_000,
               args: peer_code_path_args()
             }
           ]},
        restart: :temporary,
        shutdown: 10_000
      })

    peer_node = :peer.call(peer, :erlang, :node, [])
    assert Node.connect(peer_node)
    assert :ok = :peer.call(peer, :global, :sync, [])

    assert :ok =
             :peer.call(peer, Application, :put_env, [
               :topics_club_core,
               :engine_client_adapter,
               RpcAdapter
             ])

    assert :ok =
             :peer.call(peer, Application, :put_env, [
               :topics_club_gateway,
               :engine_node,
               node()
             ])

    {peer, peer_node}
  end

  defp remote(peer, function, arguments) do
    :peer.call(peer, EngineClient, function, arguments, 40_000)
  end

  defp peer_code_path_args do
    :code.get_path()
    |> Enum.reject(&(List.to_string(&1) == "."))
    |> Enum.flat_map(&[~c"-pa", &1])
  end
end
