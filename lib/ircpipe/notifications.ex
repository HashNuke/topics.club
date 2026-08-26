defmodule Ircpipe.Notifications do
  import Ecto.Query

  alias Ircpipe.Accounts.{Scope, User, UserToken}

  alias Ircpipe.Chat.{
    ChannelMembership,
    DirectMessageThread,
    Message,
    Notification,
    ServerConnection
  }

  alias Ircpipe.Notifications.{PushSubscription, PushSubscriptionRateLimit, PushWorker, WebPush}
  alias Ircpipe.Repo

  @max_push_subscriptions_per_user 5
  @push_subscription_creation_limit 10
  @push_subscription_window_seconds 3_600

  def push_config do
    %{configured: WebPush.configured?(), vapid_public_key: WebPush.public_key()}
  end

  def push_config(%Scope{user: user}, session_token) when is_binary(session_token) do
    installation_id = current_session_installation_id(user.id, session_token)

    push_config()
    |> Map.put(:session_generation, UserToken.session_token_fingerprint(session_token))
    |> Map.put(:session_registration_confirmed, is_binary(installation_id))
    |> Map.put(:session_installation_id, installation_id)
  end

  def push_config(%Scope{}, _session_token) do
    push_config()
    |> Map.put(:session_generation, nil)
    |> Map.put(:session_registration_confirmed, false)
    |> Map.put(:session_installation_id, nil)
  end

  def notification_account(%Scope{user: user}, session_token) when is_binary(session_token) do
    case Ircpipe.Accounts.get_user_by_session_token(session_token) do
      {session_user, _inserted_at} when session_user.id == user.id ->
        %{
          user_id: user.id,
          session_generation: UserToken.session_token_fingerprint(session_token)
        }

      _invalid_session ->
        %{user_id: nil, session_generation: nil}
    end
  end

  def notification_account(%Scope{}, _session_token),
    do: %{user_id: nil, session_generation: nil}

  def notification_account(nil, _session_token),
    do: %{user_id: nil, session_generation: nil}

  def notification_eligible?(%Scope{user: user}, session_token, notification_id, generation)
      when is_binary(session_token) and is_integer(notification_id) and is_binary(generation) do
    current_generation = UserToken.session_token_fingerprint(session_token)

    with true <- Plug.Crypto.secure_compare(current_generation, generation),
         {session_user, _inserted_at} <- Ircpipe.Accounts.get_user_by_session_token(session_token),
         true <- session_user.id == user.id,
         %{user_id: notification_user_id, server_enabled: true, channel_enabled: true} <-
           delivery_record(notification_id) do
      notification_user_id == user.id
    else
      _ineligible -> false
    end
  end

  def notification_eligible?(scope, session_token, notification_id, generation)
      when is_binary(notification_id) do
    case Integer.parse(notification_id) do
      {parsed_id, ""} -> notification_eligible?(scope, session_token, parsed_id, generation)
      _invalid_id -> false
    end
  end

  def notification_eligible?(_scope, _session_token, _notification_id, _generation), do: false

  defp current_session_installation_id(user_id, session_token) do
    UserToken.valid_session_token_query()
    |> where([token], token.user_id == ^user_id and token.token == ^session_token)
    |> join(:inner, [token], subscription in PushSubscription,
      on: subscription.user_token_id == token.id and subscription.user_id == ^user_id
    )
    |> order_by([_token, subscription], desc: subscription.updated_at)
    |> select([_token, subscription], subscription.installation_id)
    |> limit(1)
    |> Repo.one()
  end

  def upsert_subscription(scope, session_token, attrs, user_agent \\ nil)

  def upsert_subscription(%Scope{user: user}, session_token, attrs, user_agent)
      when is_binary(session_token) do
    endpoint = Map.get(attrs, "endpoint") || Map.get(attrs, :endpoint)
    endpoint_hash = endpoint_hash(endpoint)
    installation_id = installation_id(attrs)

    changeset =
      %PushSubscription{user_id: user.id, endpoint_hash: endpoint_hash}
      |> PushSubscription.changeset(Map.put(stringify_keys(attrs), "user_agent", user_agent))

    if changeset.valid? do
      Repo.transaction(fn ->
        lock_subscription_user!(user.id)

        user_token =
          lock_session_token(user.id, session_token) || Repo.rollback(:session_expired)

        maybe_pause_push_registration()

        if Repo.exists?(
             from(subscription in PushSubscription,
               where:
                 subscription.endpoint_hash == ^endpoint_hash and
                   subscription.user_id != ^user.id
             )
           ) do
          Repo.rollback(:endpoint_owned_by_another_account)
        end

        existing =
          PushSubscription
          |> where(
            [subscription],
            subscription.user_id == ^user.id and
              (subscription.endpoint_hash == ^endpoint_hash or
                 subscription.installation_id == ^installation_id)
          )
          |> order_by(
            [subscription],
            desc: subscription.endpoint_hash == ^endpoint_hash,
            desc: subscription.updated_at
          )
          |> limit(1)
          |> Repo.one()

        canonical_installation_id =
          if existing && existing.endpoint_hash == endpoint_hash,
            do: existing.installation_id,
            else: installation_id

        if is_nil(existing) do
          enforce_subscription_cap!(user.id)
          record_subscription_creation!(user.id)
        end

        from(subscription in PushSubscription,
          where:
            subscription.user_id == ^user.id and
              (subscription.endpoint_hash == ^endpoint_hash or
                 subscription.installation_id == ^installation_id)
        )
        |> Repo.delete_all()

        case changeset
             |> Ecto.Changeset.put_change(:installation_id, canonical_installation_id)
             |> Ecto.Changeset.put_change(:user_token_id, user_token.id)
             |> Repo.insert() do
          {:ok, subscription} -> subscription
          {:error, failed_changeset} -> Repo.rollback(failed_changeset)
        end
      end)
    else
      {:error, changeset}
    end
  end

  def upsert_subscription(%Scope{}, _session_token, _attrs, _user_agent),
    do: {:error, :session_expired}

  def rotate_session_with_subscriptions(%Scope{user: user}, previous_session_token)
      when is_binary(previous_session_token) do
    Repo.transaction(fn ->
      lock_subscription_user!(user.id)

      previous =
        UserToken
        |> where(
          [token],
          token.user_id == ^user.id and token.context == "session" and
            token.token == ^previous_session_token
        )
        |> lock("FOR UPDATE")
        |> Repo.one()

      if UserToken.session_token_valid?(previous) do
        maybe_pause_session_rotation()
        {next_session_token, next_user_token} = UserToken.build_session_token(user)
        next = Repo.insert!(next_user_token)

        rebound_count =
          from(subscription in PushSubscription,
            where:
              subscription.user_id == ^user.id and
                subscription.user_token_id == ^previous.id
          )
          |> Repo.update_all(set: [user_token_id: next.id])
          |> elem(0)

        Repo.delete!(previous)
        %{session_token: next_session_token, rebound_count: rebound_count}
      else
        Repo.rollback(:invalid_session)
      end
    end)
  end

  defp maybe_pause_session_rotation do
    if test_pid = Application.get_env(:ircpipe, :pause_session_rotation) do
      send(test_pid, {:session_rotation_paused, self()})

      receive do
        :continue_session_rotation -> :ok
      end
    end
  end

  defp enforce_subscription_cap!(user_id) do
    count =
      PushSubscription
      |> where([subscription], subscription.user_id == ^user_id)
      |> Repo.aggregate(:count)

    if count >= @max_push_subscriptions_per_user,
      do: Repo.rollback(:too_many_push_subscriptions)
  end

  defp record_subscription_creation!(user_id) do
    now = DateTime.utc_now(:second)

    Repo.insert_all(
      PushSubscriptionRateLimit,
      [
        %{
          user_id: user_id,
          window_started_at: now,
          creation_count: 0,
          inserted_at: now,
          updated_at: now
        }
      ],
      on_conflict: :nothing,
      conflict_target: [:user_id]
    )

    limit =
      PushSubscriptionRateLimit
      |> where([rate_limit], rate_limit.user_id == ^user_id)
      |> lock("FOR UPDATE")
      |> Repo.one!()

    if DateTime.diff(now, limit.window_started_at, :second) >=
         @push_subscription_window_seconds do
      limit
      |> Ecto.Changeset.change(window_started_at: now, creation_count: 1)
      |> Repo.update!()
    else
      if limit.creation_count >= @push_subscription_creation_limit do
        Repo.rollback(:push_subscription_rate_limited)
      end

      limit
      |> Ecto.Changeset.change(creation_count: limit.creation_count + 1)
      |> Repo.update!()
    end
  end

  defp lock_subscription_user!(user_id) do
    User
    |> where([user], user.id == ^user_id)
    |> lock("FOR UPDATE")
    |> Repo.one!()
  end

  defp lock_session_token(user_id, session_token) do
    token =
      UserToken
      |> where(
        [token],
        token.user_id == ^user_id and token.token == ^session_token and
          token.context == "session"
      )
      |> lock("FOR SHARE")
      |> Repo.one()

    if UserToken.session_token_valid?(token), do: token
  end

  defp maybe_pause_push_registration do
    if test_pid = Application.get_env(:ircpipe, :pause_push_registration) do
      send(test_pid, {:push_registration_paused, self()})

      receive do
        :continue_push_registration -> :ok
      end
    end
  end

  def delete_subscription(%Scope{user: user}, installation_id) do
    from(subscription in PushSubscription,
      where: subscription.user_id == ^user.id and subscription.installation_id == ^installation_id
    )
    |> Repo.delete_all()

    :ok
  end

  def update_server_preference(%Scope{user: user}, id, enabled) when is_boolean(enabled) do
    Repo.transaction(fn ->
      connection =
        ServerConnection
        |> where([connection], connection.id == ^id and connection.user_id == ^user.id)
        |> lock("FOR UPDATE")
        |> Repo.one!()

      connection
      |> Ecto.Changeset.change(mention_notifications_enabled: enabled)
      |> Repo.update!()
    end)
    |> unwrap_transaction()
    |> broadcast_preference(user.id, :server)
  end

  def update_channel_preference(%Scope{user: user}, id, enabled) when is_boolean(enabled) do
    Repo.transaction(fn ->
      membership =
        ChannelMembership
        |> where([membership], membership.id == ^id and membership.user_id == ^user.id)
        |> Repo.one!()

      lock_server_connection!(membership.server_connection_id)

      membership
      |> Ecto.Changeset.change(mention_notifications_enabled: enabled)
      |> Repo.update!()
    end)
    |> unwrap_transaction()
    |> broadcast_preference(user.id, :channel)
  end

  def enqueue_delivery(%Notification{id: notification_id}) do
    if WebPush.configured?() do
      %{"notification_id" => notification_id}
      |> PushWorker.new()
      |> Oban.insert()
    else
      {:ok, :push_not_configured}
    end
  end

  def deliver_notification(notification_id) do
    case notification_server_connection_id(notification_id) do
      nil ->
        {:cancel, :notification_not_found}

      server_connection_id ->
        Repo.transaction(fn ->
          lock_server_connection!(server_connection_id)

          case delivery_record(notification_id) do
            nil -> {:result, {:cancel, :notification_not_found}}
            %{server_enabled: false} -> {:result, :ok}
            %{channel_enabled: false} -> {:result, :ok}
            record -> {:deliveries, send_to_subscriptions(record)}
          end
        end)
        |> case do
          {:ok, {:result, result}} -> result
          {:ok, {:deliveries, deliveries}} -> finalize_deliveries(deliveries)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp notification_server_connection_id(notification_id) do
    from(notification in Notification,
      left_join: membership in ChannelMembership,
      on: membership.id == notification.channel_membership_id,
      left_join: thread in DirectMessageThread,
      on: thread.id == notification.direct_message_thread_id,
      where: notification.id == ^notification_id,
      select: {membership.server_connection_id, thread.server_connection_id}
    )
    |> Repo.one()
    |> case do
      {channel_server_id, direct_server_id} -> channel_server_id || direct_server_id
      nil -> nil
    end
  end

  defp delivery_record(notification_id) do
    direct_message_delivery_record(notification_id) || mention_delivery_record(notification_id)
  end

  defp mention_delivery_record(notification_id) do
    from(notification in Notification,
      join: message in Message,
      on: message.id == notification.message_id,
      join: membership in ChannelMembership,
      on: membership.id == notification.channel_membership_id,
      join: connection in ServerConnection,
      on: connection.id == membership.server_connection_id,
      where:
        notification.id == ^notification_id and is_nil(notification.read_at) and
          message.mentioned == true,
      select: %{
        notification_id: notification.id,
        user_id: notification.user_id,
        message_id: message.id,
        kind: "mention",
        body: message.body,
        nick: message.nick,
        channel: membership.channel,
        channel_membership_id: membership.id,
        server_name: connection.name,
        server_enabled: connection.mention_notifications_enabled,
        channel_enabled: membership.mention_notifications_enabled
      }
    )
    |> Repo.one()
  end

  defp direct_message_delivery_record(notification_id) do
    from(notification in Notification,
      join: message in Message,
      on: message.id == notification.message_id,
      join: thread in DirectMessageThread,
      on: thread.id == notification.direct_message_thread_id,
      join: connection in ServerConnection,
      on: connection.id == thread.server_connection_id,
      where:
        notification.id == ^notification_id and is_nil(notification.read_at) and
          is_nil(thread.blocked_at) and is_nil(thread.closed_at),
      select: %{
        notification_id: notification.id,
        user_id: notification.user_id,
        message_id: message.id,
        kind: "direct_message",
        body: message.body,
        nick: message.nick,
        peer_nick: thread.peer_nick,
        direct_message_thread_id: thread.id,
        server_name: connection.name,
        server_enabled: true,
        channel_enabled: true
      }
    )
    |> Repo.one()
  end

  defp send_to_subscriptions(record) do
    subscriptions =
      PushSubscription
      |> where([subscription], subscription.user_id == ^record.user_id)
      |> order_by([subscription], desc: subscription.updated_at)
      |> limit(^@max_push_subscriptions_per_user)
      |> Repo.all()

    maybe_pause_push_delivery_snapshot()

    deliverable_subscriptions =
      Enum.flat_map(subscriptions, fn subscription ->
        lock_deliverable_subscription(
          subscription.id,
          record.user_id,
          subscription.user_token_id,
          3
        )
      end)

    results =
      Task.async_stream(
        deliverable_subscriptions,
        &send_to_subscription(&1, record),
        timeout: 20_000,
        ordered: false
      )
      |> Enum.to_list()

    results
  end

  defp lock_deliverable_subscription(_subscription_id, _user_id, _token_id, 0), do: []

  defp lock_deliverable_subscription(subscription_id, user_id, token_id, attempts_left) do
    session_token =
      UserToken
      |> where(
        [token],
        token.id == ^token_id and token.user_id == ^user_id and token.context == "session"
      )
      |> lock("FOR SHARE")
      |> Repo.one()

    current_subscription =
      PushSubscription
      |> where(
        [current],
        current.id == ^subscription_id and current.user_id == ^user_id and
          current.user_token_id == ^token_id
      )
      |> lock("FOR UPDATE")
      |> Repo.one()

    cond do
      current_subscription && UserToken.session_token_valid?(session_token) ->
        [
          {current_subscription, UserToken.session_token_fingerprint(session_token.token)}
        ]

      current_subscription ->
        Repo.delete!(current_subscription)
        []

      next_token_id = current_subscription_token_id(subscription_id, user_id) ->
        lock_deliverable_subscription(
          subscription_id,
          user_id,
          next_token_id,
          attempts_left - 1
        )

      true ->
        []
    end
  end

  defp current_subscription_token_id(subscription_id, user_id) do
    PushSubscription
    |> where([current], current.id == ^subscription_id and current.user_id == ^user_id)
    |> select([current], current.user_token_id)
    |> Repo.one()
  end

  defp maybe_pause_push_delivery_snapshot do
    if test_pid = Application.get_env(:ircpipe, :pause_push_delivery_snapshot) do
      send(test_pid, {:push_delivery_snapshot_paused, self()})

      receive do
        :continue_push_delivery_snapshot -> :ok
        {:continue_push_delivery_snapshot, callback} when is_function(callback, 0) -> callback.()
      end
    end
  end

  defp send_to_subscription({subscription, session_generation}, record) do
    payload = notification_payload(record) |> Map.put(:session_generation, session_generation)
    {subscription, push_sender().send(subscription, payload)}
  end

  defp finalize_deliveries(deliveries) do
    Enum.each(deliveries, fn
      {:ok, {subscription, :ok}} -> mark_success(subscription)
      {:ok, {subscription, {:error, :expired}}} -> delete_expired(subscription)
      _delivery -> :ok
    end)

    if Enum.any?(deliveries, &retryable_result?/1),
      do: {:error, :push_service_unavailable},
      else: :ok
  end

  defp notification_payload(%{kind: "mention"} = record) do
    %{
      title: "#{record.channel} on #{record.server_name}",
      body: "#{record.nick}: #{String.slice(record.body, 0, 240)}",
      tag: "notification_mention:message:#{record.message_id}",
      notification_id: record.notification_id,
      message_id: record.message_id,
      user_id: record.user_id,
      buffer_id: "channel:#{record.channel_membership_id}",
      url: "/app?buffer=channel:#{record.channel_membership_id}"
    }
  end

  defp notification_payload(%{kind: "direct_message"} = record) do
    %{
      title: "#{record.peer_nick} on #{record.server_name}",
      body: "#{record.nick}: #{String.slice(record.body, 0, 240)}",
      tag: "notification_direct_message:message:#{record.message_id}",
      notification_id: record.notification_id,
      message_id: record.message_id,
      user_id: record.user_id,
      buffer_id: "direct:#{record.direct_message_thread_id}",
      url: "/app?buffer=direct:#{record.direct_message_thread_id}"
    }
  end

  defp mark_success(subscription) do
    PushSubscription
    |> where([current], current.id == ^subscription.id)
    |> Repo.update_all(set: [last_success_at: DateTime.utc_now(:second)])

    :ok
  end

  defp delete_expired(subscription) do
    PushSubscription
    |> where([current], current.id == ^subscription.id)
    |> Repo.delete_all()

    :ok
  end

  defp retryable_result?({:ok, {_subscription, {:error, {:retryable, _status}}}}), do: true
  defp retryable_result?({:ok, {_subscription, {:error, {:transport, _reason}}}}), do: true
  defp retryable_result?({:exit, _reason}), do: true
  defp retryable_result?(_result), do: false

  defp lock_server_connection!(server_connection_id) do
    ServerConnection
    |> where([connection], connection.id == ^server_connection_id)
    |> lock("FOR UPDATE")
    |> Repo.one!()
  end

  defp unwrap_transaction({:ok, value}), do: {:ok, value}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}

  defp broadcast_preference({:ok, record} = result, user_id, scope) do
    payload = %{
      scope: Atom.to_string(scope),
      id: record.id,
      mention_notifications_enabled: record.mention_notifications_enabled
    }

    Phoenix.PubSub.broadcast(
      Ircpipe.PubSub,
      "user:#{user_id}",
      {:notification_preference, payload}
    )

    result
  end

  defp broadcast_preference(result, _user_id, _scope), do: result

  defp endpoint_hash(endpoint) when is_binary(endpoint), do: :crypto.hash(:sha256, endpoint)
  defp endpoint_hash(_endpoint), do: <<>>

  defp installation_id(attrs),
    do: Map.get(attrs, "installation_id") || Map.get(attrs, :installation_id)

  defp stringify_keys(attrs),
    do: Map.new(attrs, fn {key, value} -> {to_string(key), value} end)

  defp push_sender,
    do: Application.get_env(:ircpipe, :push_sender, WebPush)
end
