defmodule TopicsClub.Chat.MessageIngestion do
  @moduledoc false

  import Ecto.Query

  alias TopicsClub.Accounts.User

  alias TopicsClub.Chat.{
    BufferEvents,
    ChannelMembership,
    MentionDetection,
    Message,
    Notification,
    NotificationEventsWorker,
    PresenceMembershipLookup,
    Retention,
    ServerConnection,
    ServerConnectionLock
  }

  alias TopicsClub.Repo

  def record_channel(
        %ServerConnection{} = connection,
        channel,
        nick,
        body,
        kind \\ "message",
        metadata \\ %{},
        casemapping \\ :rfc1459
      ) do
    assert_transaction_owner!()
    attention? = metadata_value(metadata, :direction) != "outgoing"

    Repo.transaction(fn ->
      active_connection = ServerConnectionLock.lock_active!(connection.id)

      membership =
        PresenceMembershipLookup.find(active_connection, channel, casemapping, "joined") ||
          Repo.rollback(:channel_membership_not_found)

      user = Repo.get!(User, active_connection.user_id)

      mentioned =
        attention? and
          MentionDetection.mentioned?(body, connection.nickname, casemapping)

      {:ok, message} =
        %Message{
          user_id: active_connection.user_id,
          server_connection_id: active_connection.id,
          channel_membership_id: membership.id
        }
        |> Message.changeset(%{
          kind: kind,
          nick: nick,
          hostmask: metadata_value(metadata, :hostmask),
          sender_role: metadata_value(metadata, :sender_role),
          service: metadata_value(metadata, :service),
          metadata: stringify_metadata(metadata),
          body: body,
          mentioned: mentioned,
          occurred_at: DateTime.utc_now(:second)
        })
        |> Repo.insert()

      membership =
        if attention? do
          counters = [inc: [unread_count: 1]]

          counters =
            if mentioned,
              do: Keyword.update!(counters, :inc, &([mention_count: 1] ++ &1)),
              else: counters

          {1, _} =
            Repo.update_all(from(m in ChannelMembership, where: m.id == ^membership.id), counters)

          Repo.get!(ChannelMembership, membership.id)
        else
          membership
        end

      notification =
        if mentioned do
          {:ok, notification} =
            %Notification{
              user_id: active_connection.user_id,
              message_id: message.id,
              channel_membership_id: membership.id
            }
            |> Notification.changeset(%{})
            |> Repo.insert()

          notification
        end

      if notification do
        %{
          notification_id: notification.id,
          user_id: active_connection.user_id,
          occurred_at: DateTime.to_iso8601(message.occurred_at)
        }
        |> NotificationEventsWorker.new()
        |> then(&Oban.insert!(TopicsClub.EngineOban, &1))
      end

      Retention.prune(user)
      {message, notification, active_connection, membership}
    end)
    |> case do
      {:ok, {message, _notification, active_connection, membership}} ->
        _effects =
          ServerConnectionLock.serialize_effects(active_connection.id, fn effect_connection ->
            case Repo.get(ChannelMembership, membership.id) do
              %ChannelMembership{} = current_membership ->
                BufferEvents.attention_message(message, current_membership, effect_connection)

              nil ->
                :ok
            end
          end)

        {:ok, %{message | channel_membership: membership, server_connection: active_connection}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def record_server(
        %ServerConnection{} = connection,
        body,
        kind \\ "system",
        nick \\ nil,
        metadata \\ %{}
      ) do
    assert_transaction_owner!()
    user = Repo.get!(User, connection.user_id)

    Repo.transaction(fn ->
      active_connection = ServerConnectionLock.lock_active!(connection.id)

      {:ok, message} =
        %Message{
          user_id: active_connection.user_id,
          server_connection_id: active_connection.id
        }
        |> Message.changeset(%{
          kind: kind,
          nick: nick || active_connection.host,
          service: metadata_value(metadata, :service),
          metadata: stringify_metadata(metadata),
          body: body,
          mentioned: false,
          occurred_at: DateTime.utc_now(:second)
        })
        |> Repo.insert()

      {1, _} =
        Repo.update_all(
          from(c in ServerConnection, where: c.id == ^active_connection.id),
          inc: [unread_count: 1]
        )

      Retention.prune(user)
      {message, active_connection}
    end)
    |> case do
      {:ok, {message, active_connection}} ->
        _effects =
          ServerConnectionLock.serialize_effects(active_connection.id, fn effect_connection ->
            BufferEvents.server_message(message, effect_connection)
          end)

        {:ok, message}

      error ->
        error
    end
  end

  defp metadata_value(metadata, key) do
    Map.get(metadata, key) || Map.get(metadata, Atom.to_string(key))
  end

  defp stringify_metadata(metadata) when is_map(metadata) do
    Map.new(metadata, fn {key, value} -> {to_string(key), value} end)
  end

  defp assert_transaction_owner! do
    if Repo.in_transaction?() do
      raise ArgumentError, "cannot ingest messages inside an existing transaction"
    end
  end
end
