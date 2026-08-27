defmodule Ircpipe.Chat.MessageIngestion do
  @moduledoc false

  import Ecto.Query

  alias Ircpipe.Accounts.User

  alias Ircpipe.Chat.{
    BufferEvents,
    ChannelMembership,
    MentionDetection,
    Message,
    Notification,
    Retention,
    ServerConnection
  }

  alias Ircpipe.Irc.Identifier
  alias Ircpipe.Notifications.Delivery
  alias Ircpipe.Repo

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

    membership =
      channel_membership(connection, channel, casemapping, "joined") ||
        raise(Ecto.NoResultsError, queryable: ChannelMembership)

    user = Repo.get!(User, connection.user_id)
    attention? = metadata_value(metadata, :direction) != "outgoing"
    mentioned = attention? and MentionDetection.mentioned?(body, connection.nickname, casemapping)

    Repo.transaction(fn ->
      {:ok, message} =
        %Message{
          user_id: connection.user_id,
          server_connection_id: connection.id,
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

      if attention? do
        counters = [inc: [unread_count: 1]]

        counters =
          if mentioned,
            do: Keyword.update!(counters, :inc, &([mention_count: 1] ++ &1)),
            else: counters

        {1, _} =
          Repo.update_all(from(m in ChannelMembership, where: m.id == ^membership.id), counters)
      end

      notification =
        if mentioned do
          {:ok, notification} =
            %Notification{
              user_id: connection.user_id,
              message_id: message.id,
              channel_membership_id: membership.id
            }
            |> Notification.changeset(%{})
            |> Repo.insert()

          notification
        end

      Retention.prune(user)
      {message, notification}
    end)
    |> case do
      {:ok, {message, notification}} ->
        if notification, do: Delivery.enqueue(notification)
        BufferEvents.message(message, membership, connection)

        {:ok, %{message | channel_membership: membership, server_connection: connection}}

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
      {:ok, message} =
        %Message{
          user_id: connection.user_id,
          server_connection_id: connection.id
        }
        |> Message.changeset(%{
          kind: kind,
          nick: nick || connection.host,
          service: metadata_value(metadata, :service),
          metadata: stringify_metadata(metadata),
          body: body,
          mentioned: false,
          occurred_at: DateTime.utc_now(:second)
        })
        |> Repo.insert()

      {1, _} =
        Repo.update_all(
          from(c in ServerConnection, where: c.id == ^connection.id),
          inc: [unread_count: 1]
        )

      Retention.prune(user)
      message
    end)
    |> case do
      {:ok, message} ->
        BufferEvents.server_message(message, connection)
        {:ok, message}

      error ->
        error
    end
  end

  defp channel_membership(connection, channel, casemapping, status) do
    query =
      from(m in ChannelMembership,
        where: m.server_connection_id == ^connection.id
      )

    query = if status, do: where(query, [m], m.status == ^status), else: query
    key = Identifier.key(channel, casemapping)

    query
    |> Repo.all()
    |> Enum.find(&(Identifier.key(&1.channel, casemapping) == key))
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
