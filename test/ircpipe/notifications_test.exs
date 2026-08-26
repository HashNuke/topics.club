defmodule Ircpipe.NotificationsTest do
  use Ircpipe.DataCase, async: false
  use Oban.Testing, repo: Ircpipe.Repo

  alias Ircpipe.AccountsFixtures
  alias Ircpipe.Chat
  alias Ircpipe.Chat.Notification
  alias Ircpipe.Notifications
  alias Ircpipe.Notifications.{PushSubscription, PushWorker, WebPush}

  setup do
    previous_sender = Application.get_env(:ircpipe, :push_sender)
    previous_pid = Application.get_env(:ircpipe, :push_test_pid)
    previous_result = Application.get_env(:ircpipe, :push_test_result)
    previous_pause = Application.get_env(:ircpipe, :pause_push_delivery)

    Application.put_env(:ircpipe, :push_sender, Ircpipe.PushTestTransport)
    Application.put_env(:ircpipe, :push_test_pid, self())
    Application.put_env(:ircpipe, :push_test_result, :ok)

    on_exit(fn ->
      restore_env(:push_sender, previous_sender)
      restore_env(:push_test_pid, previous_pid)
      restore_env(:push_test_result, previous_result)
      restore_env(:pause_push_delivery, previous_pause)
    end)

    user = AccountsFixtures.user_fixture()
    scope = AccountsFixtures.user_scope_fixture(user)

    {:ok, connection} =
      Chat.create_connection(user, %{
        "name" => "Libera",
        "host" => "irc.example.test",
        "port" => 6697,
        "nickname" => "mira"
      })

    {:ok, membership} = Chat.join_channel(user, connection, "#elixir")

    %{scope: scope, connection: connection, membership: membership}
  end

  test "stores one encrypted push subscription per installation", %{scope: scope} do
    attrs = subscription_attrs("https://push.example.test/subscription/one")

    assert {:ok, first} = Notifications.upsert_subscription(scope, attrs, "test browser")
    assert first.endpoint == attrs["endpoint"]
    assert first.user_agent == "test browser"

    raw_endpoint =
      Repo.query!("SELECT endpoint FROM push_subscriptions WHERE id = $1", [first.id]).rows
      |> List.first()
      |> List.first()

    refute raw_endpoint == attrs["endpoint"]

    assert {:ok, replacement} =
             Notifications.upsert_subscription(
               scope,
               %{attrs | "endpoint" => "https://push.example.test/subscription/two"}
             )

    assert replacement.installation_id == first.installation_id
    assert Repo.aggregate(PushSubscription, :count) == 1

    assert :ok = Notifications.delete_subscription(scope, first.installation_id)
    assert Repo.aggregate(PushSubscription, :count) == 0
  end

  test "cannot replace another user's endpoint subscription", %{scope: scope} do
    attrs = subscription_attrs("https://push.example.test/subscription/shared")
    assert {:ok, original} = Notifications.upsert_subscription(scope, attrs)

    other_scope = AccountsFixtures.user_scope_fixture()

    assert {:error, changeset} = Notifications.upsert_subscription(other_scope, attrs)
    assert "has already been taken" in errors_on(changeset).endpoint_hash
    assert Repo.get!(PushSubscription, original.id).user_id == scope.user.id
  end

  test "caps active push installations per user", %{scope: scope} do
    for index <- 1..5 do
      attrs =
        subscription_attrs("https://push.example.test/subscription/cap-#{index}")
        |> Map.put("installation_id", "browser-#{index}")

      assert {:ok, _subscription} = Notifications.upsert_subscription(scope, attrs)
    end

    overflow =
      subscription_attrs("https://push.example.test/subscription/cap-overflow")
      |> Map.put("installation_id", "browser-overflow")

    assert {:error, :too_many_push_subscriptions} =
             Notifications.upsert_subscription(scope, overflow)

    assert Repo.aggregate(PushSubscription, :count) == 5
  end

  test "rate limits repeated creation even when installations are deleted", %{scope: scope} do
    for index <- 1..10 do
      installation_id = "rotating-browser-#{index}"

      attrs =
        subscription_attrs("https://push.example.test/subscription/rotation-#{index}")
        |> Map.put("installation_id", installation_id)

      assert {:ok, _subscription} = Notifications.upsert_subscription(scope, attrs)
      assert :ok = Notifications.delete_subscription(scope, installation_id)
    end

    limited =
      subscription_attrs("https://push.example.test/subscription/rate-limited")
      |> Map.put("installation_id", "rate-limited-browser")

    assert {:error, :push_subscription_rate_limited} =
             Notifications.upsert_subscription(scope, limited)
  end

  test "validates Web Push key material at registration", %{scope: scope} do
    attrs =
      subscription_attrs("https://push.example.test/subscription/invalid-keys")
      |> Map.put("p256dh", Base.url_encode64(<<4, 0::512>>, padding: false))
      |> Map.put("auth", Base.url_encode64(:crypto.strong_rand_bytes(15), padding: false))

    assert {:error, changeset} = Notifications.upsert_subscription(scope, attrs)
    assert "must be a 65-byte uncompressed P-256 public key" in errors_on(changeset).p256dh
    assert "must decode to 16 bytes" in errors_on(changeset).auth
  end

  test "delivery fan-out stays bounded for legacy rows above the active cap", %{
    scope: scope,
    connection: connection,
    membership: membership
  } do
    for index <- 1..6 do
      attrs =
        subscription_attrs("https://push.example.test/subscription/legacy-#{index}")
        |> Map.put("installation_id", "legacy-browser-#{index}")

      %PushSubscription{
        user_id: scope.user.id,
        endpoint_hash: :crypto.hash(:sha256, attrs["endpoint"])
      }
      |> PushSubscription.changeset(attrs)
      |> Repo.insert!()
    end

    notification = mention_notification(connection, membership)
    assert :ok = Notifications.deliver_notification(notification.id)

    for _index <- 1..5 do
      assert_receive {:push_sent, _subscription, _payload}
    end

    refute_receive {:push_sent, _subscription, _payload}
  end

  test "delivers mention payloads when both preference gates are enabled", %{
    scope: scope,
    connection: connection,
    membership: membership
  } do
    assert {:ok, _subscription} =
             Notifications.upsert_subscription(
               scope,
               subscription_attrs("https://push.example.test/subscription/mention")
             )

    assert {:ok, message} =
             Chat.record_inbound_message(connection, membership.channel, "akash", "hello mira")

    notification = Repo.get_by!(Notification, message_id: message.id)

    assert :ok = Notifications.deliver_notification(notification.id)

    assert_receive {:push_sent, _subscription, payload}
    assert payload.buffer_id == "channel:#{membership.id}"
    assert payload.body == "akash: hello mira"
    assert payload.url == "/app?buffer=channel:#{membership.id}"
  end

  test "delivers direct-message payloads and suppresses blocked peers", %{
    scope: scope,
    connection: connection
  } do
    assert {:ok, _subscription} =
             Notifications.upsert_subscription(
               scope,
               subscription_attrs("https://push.example.test/subscription/direct-message")
             )

    assert {:ok, %{thread: thread, message: message}} =
             Chat.record_direct_message(
               connection,
               "akash",
               "akash",
               "hello privately",
               "message",
               %{
                 direction: "incoming",
                 account: "akash-account",
                 hostmask: "akash!user@example.test"
               }
             )

    notification = Repo.get_by!(Notification, message_id: message.id)
    assert notification.direct_message_thread_id == thread.id
    assert :ok = Notifications.deliver_notification(notification.id)

    assert_receive {:push_sent, _subscription, payload}
    assert payload.title == "akash on Libera"
    assert payload.body == "akash: hello privately"
    assert payload.buffer_id == "direct:#{thread.id}"
    assert payload.url == "/app?buffer=direct:#{thread.id}"

    assert {:ok, _blocked} = Chat.set_direct_message_blocked(scope, thread.id, true)

    message_count = Repo.aggregate(Ircpipe.Chat.Message, :count)

    assert {:ok, %{message: nil, notify?: false, dropped?: true}} =
             Chat.record_direct_message(
               connection,
               "akash_",
               "akash_",
               "blocked message",
               "message",
               %{direction: "incoming", account: "akash-account"}
             )

    assert Repo.aggregate(Ircpipe.Chat.Message, :count) == message_count
    refute_receive {:push_sent, _, _}
  end

  test "server and channel settings independently suppress delivery", %{
    scope: scope,
    connection: connection,
    membership: membership
  } do
    assert {:ok, _subscription} =
             Notifications.upsert_subscription(
               scope,
               subscription_attrs("https://push.example.test/subscription/gates")
             )

    assert {:ok, channel} =
             Notifications.update_channel_preference(scope, membership.id, false)

    refute channel.mention_notifications_enabled
    channel_notification = mention_notification(connection, membership)
    assert :ok = Notifications.deliver_notification(channel_notification.id)
    refute_receive {:push_sent, _, _}

    assert {:ok, _channel} = Notifications.update_channel_preference(scope, membership.id, true)
    assert {:ok, server} = Notifications.update_server_preference(scope, connection.id, false)
    refute server.mention_notifications_enabled

    server_notification = mention_notification(connection, membership)
    assert :ok = Notifications.deliver_notification(server_notification.id)
    refute_receive {:push_sent, _, _}
  end

  test "ordinary messages do not create deliverable notifications", %{
    connection: connection,
    membership: membership
  } do
    assert {:ok, message} =
             Chat.record_inbound_message(connection, membership.channel, "akash", "hello room")

    refute Repo.get_by(Notification, message_id: message.id)
    assert {:cancel, :notification_not_found} = Notifications.deliver_notification(-1)
    refute_receive {:push_sent, _, _}
  end

  test "read and closed direct messages cannot produce a delayed push", %{
    scope: scope,
    connection: connection
  } do
    assert {:ok, _subscription} =
             Notifications.upsert_subscription(
               scope,
               subscription_attrs("https://push.example.test/subscription/read-direct")
             )

    assert {:ok, %{thread: thread, message: first}} =
             Chat.record_direct_message(
               connection,
               "akash",
               "akash",
               "first",
               "message",
               %{direction: "incoming", account: "akash-account"}
             )

    first_notification = Repo.get_by!(Notification, message_id: first.id)
    assert {:ok, _read} = Chat.mark_direct_message_read(scope, thread.id)

    assert {:cancel, :notification_not_found} =
             Notifications.deliver_notification(first_notification.id)

    assert {:ok, %{message: second}} =
             Chat.record_direct_message(
               connection,
               "akash",
               "akash",
               "second",
               "message",
               %{direction: "incoming", account: "akash-account"}
             )

    second_notification = Repo.get_by!(Notification, message_id: second.id)
    assert {:ok, _closed} = Chat.close_direct_message_thread(scope, thread.id)

    assert {:cancel, :notification_not_found} =
             Notifications.deliver_notification(second_notification.id)

    refute_receive {:push_sent, _, _}
  end

  test "delivery and read are serialized across the final network-send boundary", %{
    scope: scope,
    connection: connection
  } do
    supervisor = start_supervised!(Task.Supervisor)
    Application.put_env(:ircpipe, :pause_push_delivery, true)

    assert {:ok, _subscription} =
             Notifications.upsert_subscription(
               scope,
               subscription_attrs("https://push.example.test/subscription/serialized")
             )

    assert {:ok, %{thread: thread, message: message}} =
             Chat.record_direct_message(
               connection,
               "akash",
               "akash",
               "race",
               "message",
               %{direction: "incoming", account: "akash-account"}
             )

    notification = Repo.get_by!(Notification, message_id: message.id)

    delivery =
      Task.Supervisor.async_nolink(supervisor, fn ->
        Notifications.deliver_notification(notification.id)
      end)

    assert_receive {:push_delivery_paused, sender_pid}

    read =
      Task.Supervisor.async_nolink(supervisor, fn ->
        Chat.mark_direct_message_read(scope, thread.id)
      end)

    refute Task.yield(read, 100)
    send(sender_pid, :continue_push_delivery)

    assert :ok = Task.await(delivery)
    assert {:ok, _read_thread} = Task.await(read)
    assert_receive {:push_sent, _subscription, %{body: "akash: race"}}
    assert Repo.reload(notification).read_at
  end

  test "outgoing messages neither create attention counters nor notifications", %{
    connection: connection,
    membership: membership
  } do
    assert {:ok, message} =
             Chat.record_inbound_message(
               connection,
               membership.channel,
               connection.nickname,
               "mira: my own message",
               "message",
               %{direction: "outgoing"}
             )

    membership = Repo.reload(membership)
    refute message.mentioned
    assert membership.unread_count == 0
    assert membership.mention_count == 0
    refute Repo.get_by(Notification, message_id: message.id)
  end

  test "mention matching uses IRC casemapping and nick boundaries", %{
    connection: connection,
    membership: membership
  } do
    assert {:ok, substring} =
             Chat.record_inbound_message(
               connection,
               membership.channel,
               "akash",
               "admirable work",
               "message",
               %{},
               :rfc1459
             )

    refute substring.mentioned

    assert {:ok, punctuated} =
             Chat.record_inbound_message(
               connection,
               membership.channel,
               "akash",
               "MIRA: ping",
               "message",
               %{},
               :rfc1459
             )

    assert punctuated.mentioned

    bracket_connection = %{connection | nickname: "nick["}

    assert {:ok, mapped} =
             Chat.record_inbound_message(
               bracket_connection,
               membership.channel,
               "akash",
               "nick{: ping",
               "message",
               %{},
               :rfc1459
             )

    assert mapped.mentioned
  end

  test "queues durable work only for mentions when Web Push is configured", %{
    connection: connection,
    membership: membership
  } do
    previous_config = Application.get_env(:ircpipe, WebPush)
    vapid = WebPush.generate_keypair()

    Application.put_env(:ircpipe, WebPush,
      public_key: vapid.public_key,
      private_key: vapid.private_key,
      subject: "mailto:notifications@example.com"
    )

    on_exit(fn -> restore_env(WebPush, previous_config) end)

    assert {:ok, ordinary} =
             Chat.record_inbound_message(connection, membership.channel, "akash", "hello room")

    refute_enqueued(worker: PushWorker)

    assert {:ok, mention} =
             Chat.record_inbound_message(connection, membership.channel, "akash", "hello mira")

    notification = Repo.get_by!(Notification, message_id: mention.id)
    refute ordinary.mentioned
    assert mention.mentioned
    assert_enqueued(worker: PushWorker, args: %{notification_id: notification.id})
  end

  test "removes expired subscriptions and retries temporary push failures", %{
    scope: scope,
    connection: connection,
    membership: membership
  } do
    assert {:ok, _subscription} =
             Notifications.upsert_subscription(
               scope,
               subscription_attrs("https://push.example.test/subscription/retry")
             )

    Application.put_env(:ircpipe, :push_test_result, {:error, :expired})
    expired_notification = mention_notification(connection, membership)

    assert :ok = Notifications.deliver_notification(expired_notification.id)
    assert Repo.aggregate(PushSubscription, :count) == 0

    assert {:ok, _subscription} =
             Notifications.upsert_subscription(
               scope,
               subscription_attrs("https://push.example.test/subscription/retry")
             )

    Application.put_env(:ircpipe, :push_test_result, {:error, {:retryable, 503}})
    retry_notification = mention_notification(connection, membership)

    assert {:error, :push_service_unavailable} =
             Notifications.deliver_notification(retry_notification.id)

    assert Repo.aggregate(PushSubscription, :count) == 1
  end

  defp mention_notification(connection, membership) do
    {:ok, message} =
      Chat.record_inbound_message(connection, membership.channel, "akash", "mira: ping")

    Repo.get_by!(Notification, message_id: message.id)
  end

  defp subscription_attrs(endpoint) do
    {public_key, _private_key} = :crypto.generate_key(:ecdh, :prime256v1)

    %{
      "installation_id" => "browser-installation",
      "endpoint" => endpoint,
      "p256dh" => Base.url_encode64(public_key, padding: false),
      "auth" => Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
    }
  end

  defp restore_env(key, nil), do: Application.delete_env(:ircpipe, key)
  defp restore_env(key, value), do: Application.put_env(:ircpipe, key, value)
end
