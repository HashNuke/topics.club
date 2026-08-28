defmodule Ircpipe.InternalEventTest do
  use ExUnit.Case, async: true

  alias Ircpipe.InternalEvent
  alias Ircpipe.InternalEvent.Data

  test "accepts every version-one event type as a plain envelope" do
    occurred_at = ~U[2026-08-28 10:11:12Z]
    data_by_type = event_data()

    assert Enum.sort(Map.keys(data_by_type)) == InternalEvent.types()

    Enum.each(InternalEvent.types(), fn type ->
      assert {:ok, event} =
               InternalEvent.new(type, 42, Map.fetch!(data_by_type, type),
                 event_id: "event:#{type}:7",
                 occurred_at: occurred_at
               )

      assert event.version == 1
      assert event.event_id == "event:#{type}:7"
      assert event.type == type
      assert event.occurred_at == "2026-08-28T10:11:12Z"
      assert event.user_id == 42
      assert event.data == Map.fetch!(data_by_type, type)

      assert :ok = InternalEvent.validate(event)
    end)
  end

  test "rejects malformed envelopes, event-specific payloads, and runtime values" do
    valid =
      InternalEvent.new!("message_committed", 42, event_data()["message_committed"],
        event_id: "message:7",
        occurred_at: ~U[2026-08-28 10:11:12Z]
      )

    assert {:error, :invalid_event} = InternalEvent.validate(%{valid | version: 2})
    assert {:error, :invalid_event} = InternalEvent.validate(%{valid | type: "browser_event"})
    assert {:error, :invalid_event} = InternalEvent.validate(%{valid | event_id: "bad id"})
    assert {:error, :invalid_event} = InternalEvent.validate(Map.put(valid, :extra, true))

    assert {:error, :invalid_event} =
             InternalEvent.validate(%{valid | data: Map.delete(valid.data, :message)})

    assert {:error, :invalid_event} =
             InternalEvent.validate(%{valid | data: Map.put(valid.data, :extra, true)})

    assert {:error, :invalid_event} =
             InternalEvent.validate(%{
               valid
               | data: put_in(valid.data, [:message], Map.delete(valid.data.message, :body))
             })

    assert {:error, :invalid_event} =
             InternalEvent.validate(%{
               valid
               | data: put_in(valid.data, [:message, :metadata], %{at: DateTime.utc_now()})
             })

    assert {:error, :invalid_event} =
             InternalEvent.validate(%{
               valid
               | data: put_in(valid.data, [:message, :metadata], %{pid: self()})
             })

    assert {:error, :invalid_event} =
             InternalEvent.new(self(), 42, %{}, event_id: "invalid:7")
  end

  test "requires exact top-level and nested data for every event type" do
    Enum.each(event_data(), fn {type, data} ->
      event =
        InternalEvent.new!(type, 42, data,
          event_id: "exact:#{type}:7",
          occurred_at: ~U[2026-08-28 10:11:12Z]
        )

      first_key = data |> Map.keys() |> hd()

      assert {:error, :invalid_event} =
               InternalEvent.validate(%{event | data: Map.delete(data, first_key)})

      assert {:error, :invalid_event} =
               InternalEvent.validate(%{event | data: Map.put(data, :unexpected, true)})
    end)

    joined = event_data()["buffer_joined"]
    joined_event = InternalEvent.new!("buffer_joined", 42, joined)

    assert {:error, :invalid_event} =
             InternalEvent.validate(%{
               joined_event
               | data: put_in(joined, [:connection], Map.delete(joined.connection, :id))
             })

    synchronized = event_data()["presence_synchronized"]
    synchronized_event = InternalEvent.new!("presence_synchronized", 42, synchronized)

    assert {:error, :invalid_event} =
             InternalEvent.validate(%{
               synchronized_event
               | data: put_in(synchronized, [:users], [%{nick: "incomplete"}])
             })
  end

  test "accepts each canonical message destination and rejects mixed shapes" do
    channel = event_data()["message_committed"]

    attention = %{channel | delivery: "channel_attention"}
    server = channel |> Map.delete(:membership) |> Map.put(:delivery, "server")

    direct = %{
      delivery: "direct",
      thread: thread_data(),
      message: %{
        message_data()
        | channel_membership_id: nil,
          direct_message_thread_id: thread_data().id
      }
    }

    for data <- [channel, attention, server, direct] do
      assert {:ok, _event} = InternalEvent.new("message_committed", 42, data)
    end

    assert {:error, :invalid_event} =
             InternalEvent.new("message_committed", 42, Map.put(server, :thread, thread_data()))
  end

  test "canonical data keeps false values and converts timestamps to plain strings" do
    assert Data.connection(%{
             id: 7,
             user_id: 42,
             name: "libera",
             host: "irc.example.test",
             port: 6697,
             use_tls: false,
             nickname: "mira",
             status: "connected",
             desired_state: "connected",
             mention_notifications_enabled: false,
             notification_preference_revision: 3
           }) == %{
             id: 7,
             user_id: 42,
             name: "libera",
             host: "irc.example.test",
             port: 6697,
             use_tls: false,
             nickname: "mira",
             status: "connected",
             desired_state: "connected",
             mention_notifications_enabled: false,
             notification_preference_revision: 3
           }

    assert Data.presence_diff(%{
             action: "join",
             user: %{nick: "mira", last_observed_at: ~U[2026-08-28 10:11:12Z]}
           }) == %{
             action: "join",
             user: %{nick: "mira", last_observed_at: "2026-08-28T10:11:12Z"}
           }
  end

  defp event_data do
    connection = connection_data()
    membership = membership_data()
    message = message_data()
    thread = thread_data()

    %{
      "buffer_joined" => %{
        connection: connection,
        membership: membership,
        status: "connected"
      },
      "buffer_left" => %{connection_id: 7, membership_id: 8, channel: "#elixir"},
      "buffer_read" => %{
        connection_id: 7,
        membership_id: 8,
        unread_count: 0,
        mention_count: 0
      },
      "connection_status_changed" => %{connection: connection, status: "connected"},
      "direct_message_thread_changed" => %{thread: thread, connection: connection},
      "direct_message_thread_closed" => %{thread: thread},
      "message_committed" => %{
        delivery: "channel",
        connection: connection,
        membership: membership,
        message: message
      },
      "notification_committed" => %{notification_id: 11},
      "presence_changed" => %{
        connection_id: 7,
        membership_id: 8,
        diff: %{action: "part", nick: "mira", nick_key: "mira"}
      },
      "presence_synchronized" => %{
        connection_id: 7,
        membership_id: 8,
        users: [presence_user_data()]
      }
    }
  end

  defp connection_data do
    %{
      id: 7,
      user_id: 42,
      name: "libera",
      host: "irc.example.test",
      port: 6697,
      use_tls: true,
      nickname: "mira",
      status: "connected",
      desired_state: "connected",
      mention_notifications_enabled: true,
      notification_preference_revision: 3
    }
  end

  defp membership_data do
    %{
      id: 8,
      user_id: 42,
      server_connection_id: 7,
      channel: "#elixir",
      status: "joined",
      auto_join: true,
      unread_count: 2,
      mention_count: 1,
      mention_notifications_enabled: true,
      notification_preference_revision: 4,
      joined_at: "2026-08-28T10:11:12Z",
      left_at: nil
    }
  end

  defp message_data do
    %{
      id: 9,
      user_id: 42,
      server_connection_id: 7,
      channel_membership_id: 8,
      direct_message_thread_id: nil,
      nick: "akash",
      hostmask: "akash!user@example.test",
      sender_role: "op",
      service: nil,
      metadata: %{},
      body: "hello",
      kind: "message",
      mentioned: false,
      occurred_at: "2026-08-28T10:11:12Z"
    }
  end

  defp thread_data do
    %{
      id: 10,
      user_id: 42,
      server_connection_id: 7,
      peer_nick: "akash",
      account: "akash-account",
      hostmask: "akash!user@example.test",
      blocked_at: nil,
      closed_at: nil,
      unread_count: 1,
      mutation_revision: 2
    }
  end

  defp presence_user_data do
    %{
      nick: "akash",
      nick_key: "akash",
      role: "op",
      status: "online",
      hostmask: "akash!user@example.test",
      last_observed_at: "2026-08-28T10:11:12Z"
    }
  end
end
