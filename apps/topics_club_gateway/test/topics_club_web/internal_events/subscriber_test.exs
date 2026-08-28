defmodule TopicsClubWeb.InternalEvents.SubscriberTest do
  use ExUnit.Case, async: false

  alias TopicsClub.InternalEvent
  alias TopicsClub.InternalEvents.PubSubAdapter
  alias TopicsClubWeb.InternalEvents.Subscriber

  test "validates and translates a cluster event into the existing browser event" do
    user_id = System.unique_integer([:positive])
    subscriber_name = {:global, {:cluster_event_subscriber_test, user_id}}

    start_supervised!({Subscriber, name: subscriber_name})
    :ok = Phoenix.PubSub.subscribe(TopicsClub.PubSub, "user:#{user_id}")

    event =
      InternalEvent.new!(
        "buffer_left",
        user_id,
        %{connection_id: 7, membership_id: 8, channel: "#elixir"},
        event_id: "cluster-subscriber-test",
        occurred_at: ~U[2026-08-28 10:11:12Z]
      )

    assert :ok = PubSubAdapter.dispatch(event)

    assert_receive {:buffer_left,
                    %{
                      event_id: "cluster-subscriber-test",
                      type: "buffer:left",
                      buffer_id: "channel:8",
                      server_connection_id: 7,
                      channel_membership_id: 8,
                      channel: "#elixir"
                    }}
  end

  test "receives and translates an event broadcast from another BEAM node" do
    started_distribution? = start_distribution()

    on_exit(fn ->
      if started_distribution?, do: :net_kernel.stop()
    end)

    {membership_ref, _members} =
      :pg.monitor(Phoenix.PubSub, TopicsClub.PubSub.Adapter)

    peer_name = :internal_event_engine_peer

    peer_pid =
      start_supervised!(%{
        id: peer_name,
        start:
          {:peer, :start_link,
           [
             %{
               name: peer_name,
               connection: :standard_io,
               shutdown: 5_000,
               args: peer_code_path_args()
             }
           ]},
        restart: :temporary,
        shutdown: 10_000
      })

    peer_node = :peer.call(peer_pid, :erlang, :node, [])
    assert Node.connect(peer_node)

    assert {:ok, _applications} =
             :peer.call(peer_pid, Application, :ensure_all_started, [:phoenix_pubsub])

    remote_pubsub_spec =
      Supervisor.child_spec(
        {Phoenix.PubSub, name: TopicsClub.PubSub, pool_size: 1},
        id: :remote_topics_club_pubsub,
        restart: :temporary
      )

    assert {:ok, remote_pubsub} =
             :peer.call(peer_pid, :supervisor, :start_child, [
               :kernel_sup,
               remote_pubsub_spec
             ])

    assert_receive {^membership_ref, :join, TopicsClub.PubSub.Adapter, joined_pids}
    assert remote_pubsub in joined_pids or Enum.any?(joined_pids, &(node(&1) == peer_node))

    user_id = System.unique_integer([:positive])
    subscriber_name = {:global, {:remote_cluster_event_subscriber_test, user_id}}
    start_supervised!({Subscriber, name: subscriber_name})
    :ok = Phoenix.PubSub.subscribe(TopicsClub.PubSub, "user:#{user_id}")

    event =
      InternalEvent.new!(
        "buffer_left",
        user_id,
        %{connection_id: 17, membership_id: 18, channel: "#distributed"},
        event_id: "cross-node-subscriber-test",
        occurred_at: ~U[2026-08-28 10:11:12Z]
      )

    assert :ok =
             :peer.call(peer_pid, PubSubAdapter, :dispatch, [event])

    assert_receive {:buffer_left,
                    %{
                      event_id: "cross-node-subscriber-test",
                      buffer_id: "channel:18",
                      channel: "#distributed"
                    }}

    first_subscriber = :global.whereis_name(elem(subscriber_name, 1))
    assert is_pid(first_subscriber)
    assert :ok = stop_supervised(Subscriber)

    second_subscriber = start_supervised!({Subscriber, name: subscriber_name})
    refute second_subscriber == first_subscriber

    restarted_event =
      InternalEvent.new!(
        "buffer_left",
        user_id,
        %{connection_id: 17, membership_id: 19, channel: "#after-restart"},
        event_id: "cross-node-after-subscriber-restart",
        occurred_at: ~U[2026-08-28 10:11:13Z]
      )

    assert :ok = :peer.call(peer_pid, PubSubAdapter, :dispatch, [restarted_event])

    assert_receive {:buffer_left,
                    %{
                      event_id: "cross-node-after-subscriber-restart",
                      buffer_id: "channel:19",
                      channel: "#after-restart"
                    }}

    assert :ok =
             :peer.call(peer_pid, :supervisor, :terminate_child, [
               :kernel_sup,
               :remote_topics_club_pubsub
             ])
  end

  defp start_distribution do
    if Node.alive?() do
      false
    else
      assert {:ok, _pid} = :net_kernel.start([:internal_event_gateway_test, :shortnames])
      true
    end
  end

  defp peer_code_path_args do
    :code.get_path()
    |> Enum.reject(&(List.to_string(&1) == "."))
    |> Enum.flat_map(&[~c"-pa", &1])
  end
end
