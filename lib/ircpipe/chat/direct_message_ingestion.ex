defmodule Ircpipe.Chat.DirectMessageIngestion do
  @moduledoc false

  alias Ircpipe.Accounts.User

  alias Ircpipe.Chat.{
    BufferEvents,
    DirectMessageStore,
    Message,
    Notification,
    NotificationEventsWorker,
    PeerIdentity,
    Retention,
    ServerConnection,
    ServerConnectionLock
  }

  alias Ircpipe.Repo

  def record(
        %ServerConnection{} = connection,
        peer_nick,
        nick,
        body,
        kind \\ "message",
        metadata \\ %{},
        casemapping \\ nil
      ) do
    if Repo.in_transaction?() do
      raise ArgumentError, "cannot ingest inside an existing transaction"
    end

    user = Repo.get!(User, connection.user_id)
    incoming? = metadata_value(metadata, :direction) == "incoming"
    mapping = casemapping || stored_casemapping(connection) || :ascii

    result =
      Repo.transaction(fn ->
        active_connection = ServerConnectionLock.lock_active!(connection.id)
        identity_keys = PeerIdentity.keys(metadata)

        blocked_thread =
          incoming? && DirectMessageStore.blocked_thread(active_connection, identity_keys)

        if blocked_thread do
          %{
            thread: blocked_thread,
            message: nil,
            notification: nil,
            notify?: false,
            dropped?: true,
            archived_threads: []
          }
        else
          with {:ok, thread, archived_threads} <-
                 DirectMessageStore.ensure_thread(
                   user,
                   active_connection,
                   peer_nick,
                   metadata,
                   incoming?,
                   mapping
                 ) do
            if incoming? and thread.blocked_at do
              %{
                thread: thread,
                message: nil,
                notification: nil,
                notify?: false,
                dropped?: true,
                archived_threads: archived_threads
              }
            else
              notify? = incoming?

              thread =
                if notify? do
                  thread
                  |> DirectMessageStore.changeset(%{
                    closed_at: nil,
                    unread_count: thread.unread_count + 1
                  })
                  |> Repo.update!()
                else
                  thread
                end

              message =
                %Message{
                  user_id: active_connection.user_id,
                  server_connection_id: active_connection.id,
                  direct_message_thread_id: thread.id
                }
                |> Message.changeset(%{
                  kind: kind,
                  nick: nick,
                  hostmask: metadata_value(metadata, :hostmask),
                  service: metadata_value(metadata, :service),
                  metadata: stringify_metadata(metadata),
                  body: body,
                  mentioned: false,
                  occurred_at: DateTime.utc_now(:second)
                })
                |> Repo.insert!()

              notification =
                if notify? do
                  %Notification{
                    user_id: user.id,
                    message_id: message.id,
                    direct_message_thread_id: thread.id
                  }
                  |> Notification.changeset(%{})
                  |> Repo.insert!()
                end

              if notification do
                %{
                  notification_id: notification.id,
                  user_id: active_connection.user_id,
                  occurred_at: DateTime.to_iso8601(message.occurred_at)
                }
                |> NotificationEventsWorker.new()
                |> then(&Oban.insert!(Ircpipe.EngineOban, &1))
              end

              Retention.prune(user)

              %{
                thread: thread,
                message: message,
                notification: notification,
                notify?: notify?,
                dropped?: false,
                archived_threads: archived_threads
              }
            end
          else
            {:error, changeset} -> Repo.rollback({:direct_message_thread, changeset})
          end
        end
      end)

    case result do
      {:ok, %{dropped?: true, archived_threads: archived_threads} = recorded} ->
        _effects =
          ServerConnectionLock.serialize_effects(connection.id, fn _active_connection ->
            Enum.each(archived_threads, &BufferEvents.direct_message_closed/1)
          end)

        {:ok, Map.delete(recorded, :archived_threads)}

      {:ok,
       %{
         thread: thread,
         message: message,
         archived_threads: archived_threads
       } = recorded} ->
        _effects =
          ServerConnectionLock.serialize_effects(connection.id, fn _active_connection ->
            Enum.each(archived_threads, &BufferEvents.direct_message_closed/1)
            BufferEvents.direct_message_thread(thread)
            BufferEvents.direct_message(message, thread)
          end)

        {:ok, Map.delete(recorded, :archived_threads)}

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

  defp stored_casemapping(%ServerConnection{casemapping: mapping}) when is_binary(mapping) do
    case mapping do
      "ascii" -> :ascii
      "strict_rfc1459" -> :strict_rfc1459
      _mapping -> :rfc1459
    end
  end

  defp stored_casemapping(%ServerConnection{}), do: nil
end
