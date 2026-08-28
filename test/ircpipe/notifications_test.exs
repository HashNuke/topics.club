defmodule Ircpipe.NotificationsTest do
  use Ircpipe.DataCase, async: false
  use Oban.Testing, repo: Ircpipe.Repo

  alias Ircpipe.Accounts
  alias Ircpipe.Accounts.{UserToken}
  alias Ircpipe.AccountsFixtures
  alias Ircpipe.Chat
  alias Ircpipe.Chat.Connections
  alias Ircpipe.Chat.DirectMessageIngestion
  alias Ircpipe.Chat.DirectMessageLifecycle
  alias Ircpipe.Chat.MessageIngestion
  alias Ircpipe.Chat.ReadState
  alias Ircpipe.Chat.Notification
  alias Ircpipe.Chat.NotificationEventsWorker

  alias Ircpipe.Notifications.{
    Delivery,
    Preferences,
    PushSubscription,
    PushRegistrations,
    PushWorker,
    SessionBindings,
    WebPush
  }

  setup do
    previous_sender = Application.get_env(:topics_club_gateway, :push_sender)
    previous_pid = Application.get_env(:topics_club_gateway, :push_test_pid)
    previous_result = Application.get_env(:topics_club_gateway, :push_test_result)
    previous_pause = Application.get_env(:topics_club_gateway, :pause_push_delivery)

    previous_registration_pause =
      Application.get_env(:topics_club_gateway, :pause_push_registration)

    previous_rotation_pause = Application.get_env(:topics_club_gateway, :pause_session_rotation)

    previous_snapshot_pause =
      Application.get_env(:topics_club_gateway, :pause_push_delivery_snapshot)

    previous_reset_pause = Application.get_env(:topics_club_gateway, :pause_session_reset)

    previous_delete_failure =
      Application.get_env(:topics_club_engine, :connection_final_delete_failure)

    Application.put_env(:topics_club_gateway, :push_sender, Ircpipe.PushTestTransport)
    Application.put_env(:topics_club_gateway, :push_test_pid, self())
    Application.put_env(:topics_club_gateway, :push_test_result, :ok)

    on_exit(fn ->
      restore_env(:push_sender, previous_sender)
      restore_env(:push_test_pid, previous_pid)
      restore_env(:push_test_result, previous_result)
      restore_env(:pause_push_delivery, previous_pause)
      restore_env(:pause_push_registration, previous_registration_pause)
      restore_env(:pause_session_rotation, previous_rotation_pause)
      restore_env(:pause_push_delivery_snapshot, previous_snapshot_pause)
      restore_env(:pause_session_reset, previous_reset_pause)
      restore_engine_env(:connection_final_delete_failure, previous_delete_failure)
    end)

    user = AccountsFixtures.user_fixture()
    scope = AccountsFixtures.user_scope_fixture(user)

    {:ok, connection} =
      Connections.create(user, %{
        "name" => "Libera",
        "host" => "irc.example.test",
        "port" => 6697,
        "nickname" => "mira"
      })

    {:ok, membership} = Chat.join_channel(user, connection, "#elixir")

    %{scope: scope, connection: connection, membership: membership}
  end

  test "registration and logout serialize on the authenticated session", %{scope: scope} do
    supervisor = start_supervised!(Task.Supervisor)
    session_token = Accounts.generate_user_session_token(scope.user)
    Application.put_env(:topics_club_gateway, :pause_push_registration, self())

    registration =
      Task.Supervisor.async_nolink(supervisor, fn ->
        PushRegistrations.register(
          scope,
          session_token,
          subscription_attrs("https://push.example.test/subscription/logout-race")
        )
      end)

    assert_receive {:push_registration_paused, registration_pid}

    logout =
      Task.Supervisor.async_nolink(supervisor, fn ->
        Accounts.delete_user_session_token(session_token)
      end)

    refute Task.yield(logout, 100)
    send(registration_pid, :continue_push_registration)

    assert {:ok, _subscription} = Task.await(registration)
    assert :ok = Task.await(logout)
    refute Repo.get_by(PushSubscription, user_id: scope.user.id)
  end

  test "concurrent rotation creates one successor and keeps subscriptions on its lineage", %{
    scope: scope
  } do
    supervisor = start_supervised!(Task.Supervisor)
    session_token = Accounts.generate_user_session_token(scope.user)

    assert {:ok, subscription} =
             PushRegistrations.register(
               scope,
               session_token,
               subscription_attrs("https://push.example.test/subscription/rotation-race")
             )

    Application.put_env(:topics_club_gateway, :pause_session_rotation, self())

    first_rotation =
      Task.Supervisor.async_nolink(supervisor, fn ->
        SessionBindings.rotate(scope, session_token)
      end)

    assert_receive {:session_rotation_paused, rotation_pid}

    second_rotation =
      Task.Supervisor.async_nolink(supervisor, fn ->
        SessionBindings.rotate(scope, session_token)
      end)

    refute Task.yield(second_rotation, 100)
    send(rotation_pid, :continue_session_rotation)

    assert {:ok, %{session_token: successor, rebound_count: 1}} = Task.await(first_rotation)
    assert {:error, :invalid_session} = Task.await(second_rotation)
    refute Accounts.get_user_by_session_token(session_token)

    successor_record = Repo.get_by!(UserToken, token: successor, context: "session")
    assert Repo.reload(subscription).user_token_id == successor_record.id

    assert :ok = Accounts.delete_user_session_token(successor)
    refute Repo.get(PushSubscription, subscription.id)
  end

  test "password reset serializes against session rotation and revokes the whole lineage", %{
    scope: scope
  } do
    supervisor = start_supervised!(Task.Supervisor)
    session_token = Accounts.generate_user_session_token(scope.user)

    assert {:ok, subscription} =
             PushRegistrations.register(
               scope,
               session_token,
               subscription_attrs("https://push.example.test/subscription/reset-rotation-race")
             )

    Application.put_env(:topics_club_gateway, :pause_session_reset, self())

    reset =
      Task.Supervisor.async_nolink(supervisor, fn ->
        Accounts.update_user_password(scope.user, %{password: "new secure password"})
      end)

    assert_receive {:session_reset_paused, reset_pid}

    rotation =
      Task.Supervisor.async_nolink(supervisor, fn ->
        SessionBindings.rotate(scope, session_token)
      end)

    refute Task.yield(rotation, 100)
    send(reset_pid, :continue_session_reset)

    assert {:ok, {_updated_user, revoked_tokens}} = Task.await(reset)
    assert Enum.any?(revoked_tokens, &(&1.token == session_token))
    assert {:error, :invalid_session} = Task.await(rotation)
    refute Repo.get(PushSubscription, subscription.id)
    refute Repo.get_by(UserToken, user_id: scope.user.id, context: "session")
  end

  test "password reset serializes against password reauthentication", %{scope: scope} do
    supervisor = start_supervised!(Task.Supervisor)
    user = AccountsFixtures.set_password(scope.user)
    authenticated_scope = AccountsFixtures.user_scope_fixture(user)
    session_token = Accounts.generate_user_session_token(user)

    assert {:ok, subscription} =
             PushRegistrations.register(
               authenticated_scope,
               session_token,
               subscription_attrs("https://push.example.test/subscription/password-reset-race")
             )

    Application.put_env(:topics_club_gateway, :pause_session_reset, self())

    reset =
      Task.Supervisor.async_nolink(supervisor, fn ->
        Accounts.update_user_password(user, %{password: "replacement password"})
      end)

    assert_receive {:session_reset_paused, reset_pid}

    reauthentication =
      Task.Supervisor.async_nolink(supervisor, fn ->
        SessionBindings.authenticate_and_rotate(
          user.email,
          AccountsFixtures.valid_user_password(),
          session_token
        )
      end)

    refute Task.yield(reauthentication, 100)
    send(reset_pid, :continue_session_reset)

    assert {:ok, {_updated_user, _revoked_tokens}} = Task.await(reset)
    assert {:error, :invalid_credentials} = Task.await(reauthentication)
    refute Repo.get(PushSubscription, subscription.id)
    refute Repo.get_by(UserToken, user_id: user.id, context: "session")
  end

  test "password reauthentication replaces an expired same-user session binding", %{scope: scope} do
    user = AccountsFixtures.set_password(scope.user)
    authenticated_scope = AccountsFixtures.user_scope_fixture(user)
    previous_token = Accounts.generate_user_session_token(user)

    assert {:ok, subscription} =
             PushRegistrations.register(
               authenticated_scope,
               previous_token,
               subscription_attrs("https://push.example.test/subscription/expired-reauth")
             )

    expired_at = DateTime.utc_now(:second) |> DateTime.add(-15, :day)

    from(token in UserToken, where: token.token == ^previous_token)
    |> Repo.update_all(set: [inserted_at: expired_at])

    assert {:ok,
            %{
              session_token: next_token,
              replaced_session_token: ^previous_token
            }} =
             SessionBindings.authenticate_and_rotate(
               user.email,
               AccountsFixtures.valid_user_password(),
               previous_token
             )

    next_user_token = Repo.get_by!(UserToken, token: next_token, context: "session")
    refute Repo.get_by(UserToken, token: previous_token, context: "session")
    assert Repo.reload(subscription).user_token_id == next_user_token.id
  end

  test "rejects registration after its authenticated session is revoked", %{scope: scope} do
    session_token = Accounts.generate_user_session_token(scope.user)
    assert :ok = Accounts.delete_user_session_token(session_token)

    assert {:error, :session_expired} =
             PushRegistrations.register(
               scope,
               session_token,
               subscription_attrs("https://push.example.test/subscription/revoked-session")
             )

    refute Repo.get_by(PushSubscription, user_id: scope.user.id)
  end

  test "cannot replace another user's endpoint subscription", %{scope: scope} do
    attrs = subscription_attrs("https://push.example.test/subscription/shared")
    assert {:ok, original} = upsert_subscription(scope, attrs)

    other_scope = AccountsFixtures.user_scope_fixture()

    assert {:error, :endpoint_owned_by_another_account} =
             upsert_subscription(other_scope, attrs)

    assert Repo.get!(PushSubscription, original.id).user_id == scope.user.id
  end

  test "caps active push installations per user", %{scope: scope} do
    for index <- 1..5 do
      attrs =
        subscription_attrs("https://push.example.test/subscription/cap-#{index}")
        |> Map.put("installation_id", "browser-#{index}")

      assert {:ok, _subscription} = upsert_subscription(scope, attrs)
    end

    overflow =
      subscription_attrs("https://push.example.test/subscription/cap-overflow")
      |> Map.put("installation_id", "browser-overflow")

    assert {:error, :too_many_push_subscriptions} =
             upsert_subscription(scope, overflow)

    assert Repo.aggregate(PushSubscription, :count) == 5
  end

  test "rate limits repeated creation even when installations are deleted", %{scope: scope} do
    for index <- 1..10 do
      installation_id = "rotating-browser-#{index}"

      attrs =
        subscription_attrs("https://push.example.test/subscription/rotation-#{index}")
        |> Map.put("installation_id", installation_id)

      assert {:ok, _subscription} = upsert_subscription(scope, attrs)
      assert :ok = PushRegistrations.unregister(scope, installation_id)
    end

    limited =
      subscription_attrs("https://push.example.test/subscription/rate-limited")
      |> Map.put("installation_id", "rate-limited-browser")

    assert {:error, :push_subscription_rate_limited} =
             upsert_subscription(scope, limited)
  end

  test "validates Web Push key material at registration", %{scope: scope} do
    attrs =
      subscription_attrs("https://push.example.test/subscription/invalid-keys")
      |> Map.put("p256dh", Base.url_encode64(<<4, 0::512>>, padding: false))
      |> Map.put("auth", Base.url_encode64(:crypto.strong_rand_bytes(15), padding: false))

    assert {:error, changeset} = upsert_subscription(scope, attrs)
    assert "must be a 65-byte uncompressed P-256 public key" in errors_on(changeset).p256dh
    assert "must decode to 16 bytes" in errors_on(changeset).auth
  end

  test "delivery fan-out stays bounded for rows above the active cap", %{
    scope: scope,
    connection: connection,
    membership: membership
  } do
    session_token = Accounts.generate_user_session_token(scope.user)
    user_token = Repo.get_by!(UserToken, token: session_token, context: "session")

    for index <- 1..6 do
      attrs =
        subscription_attrs("https://push.example.test/subscription/existing-#{index}")
        |> Map.put("installation_id", "existing-browser-#{index}")

      %PushSubscription{
        user_id: scope.user.id,
        user_token_id: user_token.id,
        endpoint_hash: :crypto.hash(:sha256, attrs["endpoint"])
      }
      |> PushSubscription.changeset(attrs)
      |> Repo.insert!()
    end

    notification = mention_notification(connection, membership)
    assert :ok = Delivery.deliver(notification.id)

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
             upsert_subscription(
               scope,
               subscription_attrs("https://push.example.test/subscription/mention")
             )

    assert {:ok, message} =
             MessageIngestion.record_channel(
               connection,
               membership.channel,
               "akash",
               "hello mira"
             )

    notification = Repo.get_by!(Notification, message_id: message.id)

    assert :ok = Delivery.deliver(notification.id)

    assert_receive {:push_sent, _subscription, payload}
    assert payload.type == "notification:mention"
    assert payload.version == 1
    assert payload.buffer_id == "channel:#{membership.id}"
    assert payload.channel_membership_id == membership.id
    assert payload.channel == "#elixir"
    assert payload.body == "akash: hello mira"
    assert payload.tag == "notification_mention:message:#{message.id}"
    assert payload.user_id == scope.user.id
    assert is_binary(payload.session_generation)
    assert payload.url == "/chat?buffer=channel:#{membership.id}"
  end

  test "delivers direct-message payloads and suppresses blocked peers", %{
    scope: scope,
    connection: connection
  } do
    assert {:ok, _subscription} =
             upsert_subscription(
               scope,
               subscription_attrs("https://push.example.test/subscription/direct-message")
             )

    assert {:ok, %{thread: thread, message: message}} =
             DirectMessageIngestion.record(
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
    assert :ok = Delivery.deliver(notification.id)

    assert_receive {:push_sent, _subscription, payload}
    assert payload.type == "notification:direct_message"
    assert payload.version == 1
    assert payload.title == "akash on Libera"
    assert payload.body == "akash: hello privately"
    assert payload.buffer_id == "direct:#{thread.id}"
    assert payload.direct_message_thread_id == thread.id
    assert payload.peer_nick == "akash"
    assert payload.tag == "notification_direct_message:message:#{message.id}"
    assert payload.user_id == scope.user.id
    assert is_binary(payload.session_generation)
    assert payload.url == "/chat?buffer=direct:#{thread.id}"

    assert {:ok, _blocked} =
             DirectMessageLifecycle.set_blocked(
               scope,
               thread.id,
               true,
               thread.mutation_revision
             )

    message_count = Repo.aggregate(Ircpipe.Chat.Message, :count)

    assert {:ok, %{message: nil, notify?: false, dropped?: true}} =
             DirectMessageIngestion.record(
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

  test "a connection marked for deletion is ineligible for mention and direct-message delivery",
       %{
         scope: scope,
         connection: connection,
         membership: membership
       } do
    assert {:ok, _subscription} =
             upsert_subscription(
               scope,
               subscription_attrs("https://push.example.test/subscription/deleting-connection")
             )

    session_token = Accounts.generate_user_session_token(scope.user)
    generation = UserToken.session_token_fingerprint(session_token)
    mention_notification = mention_notification(connection, membership)

    assert {:ok, %{message: direct_message}} =
             DirectMessageIngestion.record(
               connection,
               "akash",
               "akash",
               "do not deliver after deletion starts",
               "message",
               %{direction: "incoming", account: "akash-account"}
             )

    direct_notification = Repo.get_by!(Notification, message_id: direct_message.id)

    assert Delivery.eligible?(
             scope,
             session_token,
             mention_notification.id,
             generation
           )

    assert Delivery.eligible?(
             scope,
             session_token,
             direct_notification.id,
             generation
           )

    failure_ref = make_ref()

    Application.put_env(
      :topics_club_engine,
      :connection_final_delete_failure,
      {self(), failure_ref}
    )

    assert {:error, %{code: :invalid_state, details: %{reason: "forced_final_delete_failure"}}} =
             Connections.delete(scope.user, connection.id)

    assert_receive {:connection_final_delete_failed, _pid, ^failure_ref, connection_id}
    assert connection_id == connection.id

    refute Delivery.eligible?(
             scope,
             session_token,
             mention_notification.id,
             generation
           )

    refute Delivery.eligible?(
             scope,
             session_token,
             direct_notification.id,
             generation
           )

    assert {:cancel, :notification_not_found} = Delivery.deliver(mention_notification.id)
    assert {:cancel, :notification_not_found} = Delivery.deliver(direct_notification.id)
    refute_receive {:push_sent, _, _}
  end

  test "server and channel settings independently suppress delivery", %{
    scope: scope,
    connection: connection,
    membership: membership
  } do
    assert {:ok, _subscription} =
             upsert_subscription(
               scope,
               subscription_attrs("https://push.example.test/subscription/gates")
             )

    assert {:ok, channel} =
             Preferences.update_channel(scope, membership.id, false)

    refute channel.mention_notifications_enabled
    channel_notification = mention_notification(connection, membership)
    assert :ok = Delivery.deliver(channel_notification.id)
    refute_receive {:push_sent, _, _}

    assert {:ok, _channel} = Preferences.update_channel(scope, membership.id, true)
    assert {:ok, server} = Preferences.update_server(scope, connection.id, false)
    refute server.mention_notifications_enabled

    server_notification = mention_notification(connection, membership)
    assert :ok = Delivery.deliver(server_notification.id)
    refute_receive {:push_sent, _, _}
  end

  test "receipt eligibility changes immediately after a mention is read", %{
    scope: scope,
    connection: connection,
    membership: membership
  } do
    session_token = Accounts.generate_user_session_token(scope.user)
    generation = UserToken.session_token_fingerprint(session_token)
    notification = mention_notification(connection, membership)

    assert Delivery.eligible?(
             scope,
             session_token,
             notification.id,
             generation
           )

    assert :ok = ReadState.mark(scope.user, membership)

    refute Delivery.eligible?(
             scope,
             session_token,
             notification.id,
             generation
           )
  end

  test "receipt eligibility never loads another user's notification", %{scope: scope} do
    other_user = AccountsFixtures.user_fixture()

    {:ok, other_connection} =
      Connections.create(other_user, %{
        "name" => "Foreign",
        "host" => "irc.foreign.test",
        "port" => 6697,
        "nickname" => "mira"
      })

    {:ok, other_membership} = Chat.join_channel(other_user, other_connection, "#private")
    foreign_notification = mention_notification(other_connection, other_membership)
    session_token = Accounts.generate_user_session_token(scope.user)
    generation = UserToken.session_token_fingerprint(session_token)

    refute Delivery.eligible?(
             scope,
             session_token,
             foreign_notification.id,
             generation
           )
  end

  test "receipt eligibility follows server and channel mute changes", %{
    scope: scope,
    connection: connection,
    membership: membership
  } do
    session_token = Accounts.generate_user_session_token(scope.user)
    generation = UserToken.session_token_fingerprint(session_token)
    server_muted = mention_notification(connection, membership)

    assert {:ok, _server} = Preferences.update_server(scope, connection.id, false)

    refute Delivery.eligible?(
             scope,
             session_token,
             server_muted.id,
             generation
           )

    assert {:ok, _server} = Preferences.update_server(scope, connection.id, true)
    channel_muted = mention_notification(connection, membership)
    assert {:ok, _channel} = Preferences.update_channel(scope, membership.id, false)

    refute Delivery.eligible?(
             scope,
             session_token,
             channel_muted.id,
             generation
           )
  end

  test "receipt eligibility changes immediately after a direct message is closed or blocked", %{
    scope: scope,
    connection: connection
  } do
    session_token = Accounts.generate_user_session_token(scope.user)
    generation = UserToken.session_token_fingerprint(session_token)

    assert {:ok, %{thread: thread, message: close_message}} =
             DirectMessageIngestion.record(
               connection,
               "akash",
               "akash",
               "close me",
               "message",
               %{direction: "incoming", account: "akash-account"}
             )

    close_notification = Repo.get_by!(Notification, message_id: close_message.id)

    assert Delivery.eligible?(
             scope,
             session_token,
             close_notification.id,
             generation
           )

    assert {:ok, _closed} =
             DirectMessageLifecycle.close(scope, thread.id, thread.mutation_revision)

    refute Delivery.eligible?(
             scope,
             session_token,
             close_notification.id,
             generation
           )

    assert {:ok, %{thread: reopened, message: block_message}} =
             DirectMessageIngestion.record(
               connection,
               "akash",
               "akash",
               "block me",
               "message",
               %{direction: "incoming", account: "akash-account"}
             )

    block_notification = Repo.get_by!(Notification, message_id: block_message.id)

    assert Delivery.eligible?(
             scope,
             session_token,
             block_notification.id,
             generation
           )

    assert {:ok, _blocked} =
             DirectMessageLifecycle.set_blocked(
               scope,
               reopened.id,
               true,
               reopened.mutation_revision
             )

    refute Delivery.eligible?(
             scope,
             session_token,
             block_notification.id,
             generation
           )
  end

  test "ordinary messages do not create deliverable notifications", %{
    connection: connection,
    membership: membership
  } do
    assert {:ok, message} =
             MessageIngestion.record_channel(
               connection,
               membership.channel,
               "akash",
               "hello room"
             )

    refute Repo.get_by(Notification, message_id: message.id)
    assert {:cancel, :notification_not_found} = Delivery.deliver(-1)
    refute_receive {:push_sent, _, _}
  end

  test "read and closed direct messages cannot produce a delayed push", %{
    scope: scope,
    connection: connection
  } do
    assert {:ok, _subscription} =
             upsert_subscription(
               scope,
               subscription_attrs("https://push.example.test/subscription/read-direct")
             )

    assert {:ok, %{thread: thread, message: first}} =
             DirectMessageIngestion.record(
               connection,
               "akash",
               "akash",
               "first",
               "message",
               %{direction: "incoming", account: "akash-account"}
             )

    first_notification = Repo.get_by!(Notification, message_id: first.id)

    assert {:ok, _read} =
             DirectMessageLifecycle.mark_read(scope, thread.id, thread.mutation_revision)

    assert {:cancel, :notification_not_found} =
             Delivery.deliver(first_notification.id)

    assert {:ok, %{thread: second_thread, message: second}} =
             DirectMessageIngestion.record(
               connection,
               "akash",
               "akash",
               "second",
               "message",
               %{direction: "incoming", account: "akash-account"}
             )

    second_notification = Repo.get_by!(Notification, message_id: second.id)

    assert {:ok, _closed} =
             DirectMessageLifecycle.close(
               scope,
               second_thread.id,
               second_thread.mutation_revision
             )

    assert {:cancel, :notification_not_found} =
             Delivery.deliver(second_notification.id)

    refute_receive {:push_sent, _, _}
  end

  test "delivery and read are serialized across the final network-send boundary", %{
    scope: scope,
    connection: connection
  } do
    supervisor = start_supervised!(Task.Supervisor)
    Application.put_env(:topics_club_gateway, :pause_push_delivery, true)

    assert {:ok, _subscription} =
             upsert_subscription(
               scope,
               subscription_attrs("https://push.example.test/subscription/serialized")
             )

    assert {:ok, %{thread: thread, message: message}} =
             DirectMessageIngestion.record(
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
        Delivery.deliver(notification.id)
      end)

    assert_receive {:push_delivery_paused, sender_pid}

    read =
      Task.Supervisor.async_nolink(supervisor, fn ->
        DirectMessageLifecycle.mark_read(scope, thread.id, thread.mutation_revision)
      end)

    refute Task.yield(read, 100)
    send(sender_pid, :continue_push_delivery)

    assert :ok = Task.await(delivery)
    assert {:ok, _read_thread} = Task.await(read)
    assert_receive {:push_sent, _subscription, %{body: "akash: race"}}
    assert Repo.reload(notification).read_at
  end

  test "logout waits for an in-flight delivery and prevents later sends", %{
    scope: scope,
    connection: connection,
    membership: membership
  } do
    supervisor = start_supervised!(Task.Supervisor)
    session_token = Accounts.generate_user_session_token(scope.user)
    Application.put_env(:topics_club_gateway, :pause_push_delivery, true)

    assert {:ok, _subscription} =
             PushRegistrations.register(
               scope,
               session_token,
               subscription_attrs("https://push.example.test/subscription/logout-delivery")
             )

    notification = mention_notification(connection, membership)

    delivery =
      Task.Supervisor.async_nolink(supervisor, fn ->
        Delivery.deliver(notification.id)
      end)

    assert_receive {:push_delivery_paused, sender_pid}

    logout =
      Task.Supervisor.async_nolink(supervisor, fn ->
        Accounts.delete_user_session_token(session_token)
      end)

    refute Task.yield(logout, 100)
    send(sender_pid, :continue_push_delivery)

    assert :ok = Task.await(delivery)
    assert_receive {:push_sent, _subscription, _payload}
    assert :ok = Task.await(logout)
    refute Repo.get_by(PushSubscription, user_id: scope.user.id)
    refute_receive {:push_sent, _subscription, _payload}
  end

  test "delivery follows a subscription rebound after its initial snapshot", %{
    scope: scope,
    connection: connection,
    membership: membership
  } do
    supervisor = start_supervised!(Task.Supervisor)
    session_token = Accounts.generate_user_session_token(scope.user)

    assert {:ok, subscription} =
             PushRegistrations.register(
               scope,
               session_token,
               subscription_attrs("https://push.example.test/subscription/rebound-delivery")
             )

    notification = mention_notification(connection, membership)
    Application.put_env(:topics_club_gateway, :pause_push_delivery_snapshot, self())

    delivery =
      Task.Supervisor.async_nolink(supervisor, fn ->
        Delivery.deliver(notification.id)
      end)

    assert_receive {:push_delivery_snapshot_paused, delivery_pid}

    test_pid = self()

    send(
      delivery_pid,
      {:continue_push_delivery_snapshot,
       fn ->
         send(
           test_pid,
           {:snapshot_rotation, SessionBindings.rotate(scope, session_token)}
         )
       end}
    )

    assert_receive {:snapshot_rotation, {:ok, %{session_token: successor}}}
    assert :ok = Task.await(delivery)
    assert_receive {:push_sent, %{id: subscription_id}, _payload}
    assert subscription_id == subscription.id

    successor_record = Repo.get_by!(UserToken, token: successor, context: "session")
    assert Repo.reload(subscription).user_token_id == successor_record.id
  end

  test "expired authenticated sessions are revalidated before delivery", %{
    scope: scope,
    connection: connection,
    membership: membership
  } do
    session_token = Accounts.generate_user_session_token(scope.user)

    assert {:ok, _subscription} =
             PushRegistrations.register(
               scope,
               session_token,
               subscription_attrs("https://push.example.test/subscription/expired-session")
             )

    expired_at = DateTime.utc_now(:second) |> DateTime.add(-15, :day)

    UserToken
    |> where([token], token.token == ^session_token and token.context == "session")
    |> Repo.update_all(set: [inserted_at: expired_at])

    notification = mention_notification(connection, membership)
    assert :ok = Delivery.deliver(notification.id)
    refute_receive {:push_sent, _subscription, _payload}
    refute Repo.get_by(PushSubscription, user_id: scope.user.id)
  end

  test "outgoing messages neither create attention counters nor notifications", %{
    connection: connection,
    membership: membership
  } do
    assert {:ok, message} =
             MessageIngestion.record_channel(
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
             MessageIngestion.record_channel(
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
             MessageIngestion.record_channel(
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
             MessageIngestion.record_channel(
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
    previous_config = Application.get_env(:topics_club_gateway, WebPush)
    vapid = WebPush.generate_keypair()

    Application.put_env(:topics_club_gateway, WebPush,
      public_key: vapid.public_key,
      private_key: vapid.private_key,
      subject: "mailto:notifications@example.com"
    )

    on_exit(fn -> restore_env(WebPush, previous_config) end)

    assert {:ok, ordinary} =
             MessageIngestion.record_channel(
               connection,
               membership.channel,
               "akash",
               "hello room"
             )

    refute_enqueued(worker: PushWorker)

    assert {:ok, mention} =
             MessageIngestion.record_channel(
               connection,
               membership.channel,
               "akash",
               "hello mira"
             )

    notification = Repo.get_by!(Notification, message_id: mention.id)
    refute ordinary.mentioned
    assert mention.mentioned

    assert_enqueued(
      worker: NotificationEventsWorker,
      args: %{
        notification_id: notification.id,
        user_id: connection.user_id,
        occurred_at: DateTime.to_iso8601(mention.occurred_at)
      }
    )

    assert :ok =
             perform_job(NotificationEventsWorker, %{
               notification_id: notification.id,
               user_id: connection.user_id,
               occurred_at: DateTime.to_iso8601(mention.occurred_at)
             })

    assert_enqueued(worker: PushWorker, args: %{notification_id: notification.id})
  end

  test "removes expired subscriptions and retries temporary push failures", %{
    scope: scope,
    connection: connection,
    membership: membership
  } do
    assert {:ok, _subscription} =
             upsert_subscription(
               scope,
               subscription_attrs("https://push.example.test/subscription/retry")
             )

    Application.put_env(:topics_club_gateway, :push_test_result, {:error, :expired})
    expired_notification = mention_notification(connection, membership)

    assert :ok = Delivery.deliver(expired_notification.id)
    assert Repo.aggregate(PushSubscription, :count) == 0

    assert {:ok, _subscription} =
             upsert_subscription(
               scope,
               subscription_attrs("https://push.example.test/subscription/retry")
             )

    Application.put_env(:topics_club_gateway, :push_test_result, {:error, {:retryable, 503}})
    retry_notification = mention_notification(connection, membership)

    assert {:error, :push_service_unavailable} =
             Delivery.deliver(retry_notification.id)

    assert Repo.aggregate(PushSubscription, :count) == 1
  end

  defp mention_notification(connection, membership) do
    {:ok, message} =
      MessageIngestion.record_channel(connection, membership.channel, "akash", "mira: ping")

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

  defp upsert_subscription(scope, attrs, user_agent \\ nil) do
    session_token = Accounts.generate_user_session_token(scope.user)
    PushRegistrations.register(scope, session_token, attrs, user_agent)
  end

  defp restore_env(key, nil), do: Application.delete_env(:topics_club_gateway, key)
  defp restore_env(key, value), do: Application.put_env(:topics_club_gateway, key, value)

  defp restore_engine_env(key, nil), do: Application.delete_env(:topics_club_engine, key)
  defp restore_engine_env(key, value), do: Application.put_env(:topics_club_engine, key, value)
end
