defmodule Ircpipe.Notifications do
  import Ecto.Query

  alias Ircpipe.Accounts.Scope

  alias Ircpipe.Chat.{
    ChannelMembership,
    DirectMessageThread,
    Message,
    Notification,
    ServerConnection
  }

  alias Ircpipe.Notifications.{PushSubscription, PushWorker, WebPush}
  alias Ircpipe.Repo

  def push_config do
    %{configured: WebPush.configured?(), vapid_public_key: WebPush.public_key()}
  end

  def upsert_subscription(%Scope{user: user}, attrs, user_agent \\ nil) do
    endpoint = Map.get(attrs, "endpoint") || Map.get(attrs, :endpoint)
    endpoint_hash = endpoint_hash(endpoint)

    Repo.transaction(fn ->
      from(subscription in PushSubscription,
        where:
          subscription.user_id == ^user.id and
            (subscription.endpoint_hash == ^endpoint_hash or
               subscription.installation_id == ^installation_id(attrs))
      )
      |> Repo.delete_all()

      result =
        %PushSubscription{user_id: user.id, endpoint_hash: endpoint_hash}
        |> PushSubscription.changeset(Map.put(stringify_keys(attrs), "user_agent", user_agent))
        |> Repo.insert()

      case result do
        {:ok, subscription} -> subscription
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
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
          is_nil(thread.blocked_at),
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
      |> Repo.all()

    results =
      Task.async_stream(
        subscriptions,
        &send_to_subscription(&1, record),
        timeout: 15_000,
        ordered: false
      )
      |> Enum.to_list()

    results
  end

  defp send_to_subscription(subscription, record) do
    payload = notification_payload(record)
    {subscription, push_sender().send(subscription, payload)}
  end

  defp finalize_deliveries(deliveries) do
    Enum.each(deliveries, fn
      {:ok, {subscription, :ok}} -> mark_success(subscription)
      {:ok, {subscription, {:error, :expired}}} -> Repo.delete(subscription)
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
      tag: "mention:#{record.notification_id}",
      notification_id: record.notification_id,
      message_id: record.message_id,
      buffer_id: "channel:#{record.channel_membership_id}",
      url: "/app?buffer=channel:#{record.channel_membership_id}"
    }
  end

  defp notification_payload(%{kind: "direct_message"} = record) do
    %{
      title: "#{record.peer_nick} on #{record.server_name}",
      body: "#{record.nick}: #{String.slice(record.body, 0, 240)}",
      tag: "direct-message:#{record.notification_id}",
      notification_id: record.notification_id,
      message_id: record.message_id,
      buffer_id: "direct:#{record.direct_message_thread_id}",
      url: "/app?buffer=direct:#{record.direct_message_thread_id}"
    }
  end

  defp mark_success(subscription) do
    subscription
    |> Ecto.Changeset.change(last_success_at: DateTime.utc_now(:second))
    |> Repo.update()
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
