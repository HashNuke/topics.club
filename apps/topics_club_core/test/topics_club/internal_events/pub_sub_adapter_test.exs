defmodule TopicsClub.InternalEvents.PubSubAdapterTest do
  use ExUnit.Case, async: true

  alias TopicsClub.InternalEvent
  alias TopicsClub.InternalEvents.PubSubAdapter

  test "publishes the unchanged versioned envelope on the cluster topic" do
    event =
      InternalEvent.new!(
        "buffer_left",
        System.unique_integer([:positive]),
        %{connection_id: 7, membership_id: 8, channel: "#elixir"},
        event_id: "pubsub-adapter-test",
        occurred_at: ~U[2026-08-28 10:11:12Z]
      )

    :ok = Phoenix.PubSub.subscribe(TopicsClub.PubSub, PubSubAdapter.topic())

    assert :ok = PubSubAdapter.dispatch(event)
    assert_receive {PubSubAdapter, ^event}
  end
end
