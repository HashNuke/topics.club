defmodule TopicsClub.Notifications.Delivery do
  import Ecto.Query

  alias TopicsClub.Accounts.{Scope, UserToken}

  alias TopicsClub.Chat.{
    ChannelMembership,
    DirectMessageThread,
    Message,
    Notification,
    ServerConnection
  }

  alias TopicsClub.Notifications.{PushSubscription, PushWorker, WebPush}
  alias TopicsClub.Repo

  @max_delivery_subscriptions_per_user 5
  @max_notification_id 9_223_372_036_854_775_807

  def eligible?(%Scope{user: user}, session_token, notification_id, generation)
      when is_binary(session_token) and is_integer(notification_id) and notification_id > 0 and
             notification_id <= @max_notification_id and is_binary(generation) do
    current_generation = UserToken.session_token_fingerprint(session_token)

    with true <- Plug.Crypto.secure_compare(current_generation, generation),
         {session_user, _inserted_at} <-
           TopicsClub.Accounts.get_user_by_session_token(session_token),
         true <- session_user.id == user.id,
         %{user_id: notification_user_id, server_enabled: true, channel_enabled: true} <-
           delivery_record(notification_id, user.id) do
      notification_user_id == user.id
    else
      _ineligible -> false
    end
  end

  def eligible?(scope, session_token, notification_id, generation)
      when is_binary(notification_id) do
    case Integer.parse(notification_id) do
      {parsed_id, ""} -> eligible?(scope, session_token, parsed_id, generation)
      _invalid_id -> false
    end
  end

  def eligible?(_scope, _session_token, _notification_id, _generation), do: false

  def enqueue(%Notification{id: notification_id}) do
    enqueue(notification_id)
  end

  def enqueue(notification_id) when is_integer(notification_id) and notification_id > 0 do
    if WebPush.configured?() do
      %{"notification_id" => notification_id}
      |> PushWorker.new()
      |> then(&Oban.insert(TopicsClubWeb.Oban, &1))
    else
      {:ok, :push_not_configured}
    end
  end

  def deliver(notification_id) do
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

  defp delivery_record(notification_id, user_id \\ nil) do
    direct_message_delivery_record(notification_id, user_id) ||
      mention_delivery_record(notification_id, user_id)
  end

  defp mention_delivery_record(notification_id, user_id) do
    Notification
    |> join(:inner, [notification], message in Message, on: message.id == notification.message_id)
    |> join(:inner, [notification, _message], membership in ChannelMembership,
      on: membership.id == notification.channel_membership_id
    )
    |> join(:inner, [_notification, _message, membership], connection in ServerConnection,
      on: connection.id == membership.server_connection_id
    )
    |> where(
      [notification, message, _membership, connection],
      notification.id == ^notification_id and is_nil(notification.read_at) and
        message.mentioned == true and not connection.deleting
    )
    |> maybe_scope_notification_user(user_id)
    |> select([notification, message, membership, connection], %{
      notification_id: notification.id,
      user_id: notification.user_id,
      message_id: message.id,
      kind: "mention",
      body: message.body,
      nick: message.nick,
      channel: membership.channel,
      channel_membership_id: membership.id,
      server_connection_id: connection.id,
      server_name: connection.name,
      server_enabled: connection.mention_notifications_enabled,
      channel_enabled: membership.mention_notifications_enabled
    })
    |> Repo.one()
  end

  defp direct_message_delivery_record(notification_id, user_id) do
    Notification
    |> join(:inner, [notification], message in Message, on: message.id == notification.message_id)
    |> join(:inner, [notification, _message], thread in DirectMessageThread,
      on: thread.id == notification.direct_message_thread_id
    )
    |> join(:inner, [_notification, _message, thread], connection in ServerConnection,
      on: connection.id == thread.server_connection_id
    )
    |> where(
      [notification, _message, thread, connection],
      notification.id == ^notification_id and is_nil(notification.read_at) and
        is_nil(thread.blocked_at) and is_nil(thread.closed_at) and not connection.deleting
    )
    |> maybe_scope_notification_user(user_id)
    |> select([notification, message, thread, connection], %{
      notification_id: notification.id,
      user_id: notification.user_id,
      message_id: message.id,
      kind: "direct_message",
      body: message.body,
      nick: message.nick,
      peer_nick: thread.peer_nick,
      direct_message_thread_id: thread.id,
      server_connection_id: connection.id,
      server_name: connection.name,
      server_enabled: true,
      channel_enabled: true
    })
    |> Repo.one()
  end

  defp maybe_scope_notification_user(query, nil), do: query

  defp maybe_scope_notification_user(query, user_id) do
    where(query, [notification], notification.user_id == ^user_id)
  end

  defp send_to_subscriptions(record) do
    subscriptions =
      PushSubscription
      |> where([subscription], subscription.user_id == ^record.user_id)
      |> order_by([subscription], desc: subscription.updated_at)
      |> limit(^@max_delivery_subscriptions_per_user)
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
    if test_pid = Application.get_env(:topics_club_gateway, :pause_push_delivery_snapshot) do
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
      type: "notification:mention",
      version: 1,
      title: "#{record.channel} on #{record.server_name}",
      body: "#{record.nick}: #{String.slice(record.body, 0, 240)}",
      tag: "notification_mention:message:#{record.message_id}",
      notification_id: record.notification_id,
      message_id: record.message_id,
      user_id: record.user_id,
      channel_membership_id: record.channel_membership_id,
      channel: record.channel,
      buffer_id: "channel:#{record.channel_membership_id}",
      server_connection_id: record.server_connection_id,
      url: chat_url(record.server_connection_id, record.channel)
    }
  end

  defp notification_payload(%{kind: "direct_message"} = record) do
    %{
      type: "notification:direct_message",
      version: 1,
      title: "#{record.peer_nick} on #{record.server_name}",
      body: "#{record.nick}: #{String.slice(record.body, 0, 240)}",
      tag: "notification_direct_message:message:#{record.message_id}",
      notification_id: record.notification_id,
      message_id: record.message_id,
      user_id: record.user_id,
      direct_message_thread_id: record.direct_message_thread_id,
      peer_nick: record.peer_nick,
      buffer_id: "direct:#{record.direct_message_thread_id}",
      server_connection_id: record.server_connection_id,
      url: chat_url(record.server_connection_id, record.peer_nick)
    }
  end

  defp chat_url(server_connection_id, target) do
    "/chat/#{server_connection_id}/#{URI.encode(target, &URI.char_unreserved?/1)}"
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

  defp push_sender,
    do: Application.get_env(:topics_club_gateway, :push_sender, WebPush)
end
