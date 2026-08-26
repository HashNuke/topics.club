defmodule Ircpipe.Chat do
  import Ecto.Query

  alias Ircpipe.Accounts.Scope
  alias Ircpipe.Accounts.User

  alias Ircpipe.Chat.{
    BufferEvents,
    ChannelMembership,
    ChannelUser,
    DirectMessageBlockIdentity,
    DirectMessageThread,
    MembershipReconciler,
    Message,
    MentionDetection,
    Notification,
    PeerIdentity,
    Presence,
    Retention,
    ServerConnection
  }

  alias Ircpipe.Notifications.Delivery
  alias Ircpipe.Irc.Identifier
  alias Ircpipe.Repo

  def list_direct_message_threads(
        %User{id: user_id},
        %ServerConnection{id: connection_id, user_id: user_id}
      ) do
    DirectMessageThread
    |> where(
      [thread],
      thread.user_id == ^user_id and thread.server_connection_id == ^connection_id and
        is_nil(thread.closed_at)
    )
    |> order_by([thread], asc: fragment("lower(?)", thread.peer_nick), asc: thread.id)
    |> Repo.all()
  end

  def get_direct_message_thread!(%User{id: user_id}, id) do
    DirectMessageThread
    |> where([thread], thread.id == ^id and thread.user_id == ^user_id)
    |> preload(:server_connection)
    |> Repo.one!()
  end

  def open_direct_message(
        %User{id: user_id} = user,
        %ServerConnection{user_id: user_id} = connection,
        peer_nick
      ) do
    if Identifier.valid_nick?(peer_nick) do
      Repo.transaction(fn ->
        lock_direct_message_connection!(connection.id)

        case ensure_direct_message_thread(user, connection, peer_nick, %{}, false) do
          {:ok, thread, archived_threads} -> {thread, archived_threads}
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)
      |> case do
        {:ok, {thread, archived_threads}} ->
          Enum.each(archived_threads, &BufferEvents.direct_message_closed/1)
          {:ok, thread}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :invalid_nick}
    end
  end

  def close_direct_message_thread(%Scope{user: user}, id) do
    now = DateTime.utc_now(:second)

    Repo.transaction(fn ->
      candidate = get_direct_message_thread!(user, id)
      lock_direct_message_connection!(candidate.server_connection_id)
      thread = get_direct_message_thread!(user, id)

      updated =
        thread
        |> direct_message_thread_changeset(%{
          closed_at: now,
          last_read_at: now,
          unread_count: 0
        })
        |> Repo.update!()

      mark_direct_message_notifications_read(thread.id, now)
      updated
    end)
    |> tap(fn
      {:ok, closed} -> BufferEvents.direct_message_closed(closed)
      _result -> :ok
    end)
  end

  def set_direct_message_blocked(%Scope{user: user}, id, blocked?)
      when is_boolean(blocked?) do
    now = DateTime.utc_now(:second)

    result =
      Repo.transaction(fn ->
        candidate = get_direct_message_thread!(user, id)
        lock_direct_message_connection!(candidate.server_connection_id)
        thread = get_direct_message_thread!(user, id)
        maybe_pause_direct_message_block_after_lock(thread)

        if archived_direct_message_thread?(thread) do
          {:closed, thread}
        else
          attrs =
            if blocked? do
              %{blocked_at: now, last_read_at: now, unread_count: 0}
            else
              %{blocked_at: nil}
            end

          updated = thread |> direct_message_thread_changeset(attrs) |> Repo.update!()

          if blocked? do
            persist_direct_message_block_identities(updated)
            mark_direct_message_notifications_read(updated.id, now)
          else
            from(identity in DirectMessageBlockIdentity,
              where: identity.direct_message_thread_id == ^updated.id
            )
            |> Repo.delete_all()
          end

          {:updated, updated}
        end
      end)

    case result do
      {:ok, {:updated, updated}} ->
        BufferEvents.direct_message_thread(updated)
        {:ok, updated}

      {:ok, {:closed, closed}} ->
        BufferEvents.direct_message_closed(closed)
        {:error, :direct_message_closed}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def mark_direct_message_read(%Scope{user: user}, id) do
    now = DateTime.utc_now(:second)

    result =
      Repo.transaction(fn ->
        candidate = get_direct_message_thread!(user, id)
        lock_direct_message_connection!(candidate.server_connection_id)
        thread = get_direct_message_thread!(user, id)

        if archived_direct_message_thread?(thread) or not is_nil(thread.closed_at) do
          Repo.rollback(:direct_message_closed)
        end

        updated =
          thread
          |> direct_message_thread_changeset(%{last_read_at: now, unread_count: 0})
          |> Repo.update!()

        mark_direct_message_notifications_read(updated.id, now)
        updated
      end)

    case result do
      {:ok, updated} ->
        BufferEvents.direct_message_thread(updated)

      _result ->
        :ok
    end

    result
  end

  def send_direct_message_thread(
        %ServerConnection{user_id: user_id, id: connection_id} = connection,
        thread_id,
        body,
        transmit
      )
      when is_function(transmit, 1) do
    result =
      Repo.transaction(fn ->
        lock_direct_message_connection!(connection_id)

        thread =
          DirectMessageThread
          |> where(
            [thread],
            thread.id == ^thread_id and thread.user_id == ^user_id and
              thread.server_connection_id == ^connection_id
          )
          |> Repo.one()

        cond do
          is_nil(thread) ->
            Repo.rollback(:invalid_direct_message)

          archived_direct_message_thread?(thread) or not is_nil(thread.closed_at) ->
            Repo.rollback(:direct_message_closed)

          true ->
            case transmit.(thread.peer_nick) do
              :ok -> :ok
              {:error, reason} -> Repo.rollback(reason)
              error -> Repo.rollback(error)
            end

            maybe_pause_direct_message_send(thread)

            metadata = %{
              direction: "outgoing",
              peer_nick: thread.peer_nick,
              target: thread.peer_nick,
              account: thread.account,
              hostmask: thread.hostmask
            }

            message =
              %Message{
                user_id: user_id,
                server_connection_id: connection_id,
                direct_message_thread_id: thread.id
              }
              |> Message.changeset(%{
                kind: "message",
                nick: connection.nickname,
                hostmask: thread.hostmask,
                metadata: stringify_metadata(metadata),
                body: body,
                mentioned: false,
                occurred_at: DateTime.utc_now(:second)
              })
              |> Repo.insert!()

            Retention.prune(Repo.get!(User, user_id))

            %{thread: thread, message: message}
        end
      end)

    case result do
      {:ok, %{thread: thread, message: message} = recorded} ->
        BufferEvents.direct_message_thread(thread)
        BufferEvents.direct_message(message, thread)
        {:ok, recorded}

      error ->
        error
    end
  end

  defp maybe_pause_direct_message_send(thread) do
    case Application.get_env(:ircpipe, :pause_direct_message_send) do
      pid when is_pid(pid) ->
        send(pid, {:direct_message_send_paused, self(), thread.id})

        receive do
          {:continue_direct_message_send, thread_id} when thread_id == thread.id -> :ok
        end

      _other ->
        :ok
    end
  end

  defp maybe_pause_direct_message_block_after_lock(thread) do
    case Application.get_env(:ircpipe, :pause_direct_message_block_after_lock) do
      {test_pid, pause_ref} when is_pid(test_pid) ->
        send(test_pid, {:direct_message_block_paused, self(), pause_ref, thread.id})

        receive do
          {:continue_direct_message_block, ^pause_ref} -> :ok
        end

      _not_paused ->
        :ok
    end
  end

  def rename_direct_message_peer(
        %ServerConnection{} = connection,
        old_nick,
        new_nick,
        metadata \\ %{},
        casemapping \\ nil
      ) do
    result =
      Repo.transaction(fn ->
        lock_direct_message_connection!(connection.id)
        maybe_pause_direct_message_rename_after_lock(connection.id)
        mapping = casemapping || stored_casemapping(connection) || :ascii
        old_key = Identifier.key(old_nick, mapping)
        new_key = Identifier.key(new_nick, mapping)
        identity = PeerIdentity.details(metadata)

        case find_direct_message_thread(connection, identity.keys, old_key, new_key) do
          {nil, archived_threads} ->
            {:unchanged, archived_threads}

          {thread, archived_threads} ->
            case thread
                 |> direct_message_thread_changeset(%{
                   peer_nick: new_nick,
                   peer_key: new_key,
                   account: identity.account || thread.account,
                   hostmask: identity.hostmask || thread.hostmask,
                   identity_key: thread.identity_key || identity.primary_key
                 })
                 |> Repo.update() do
              {:ok, updated} -> {updated, archived_threads}
              {:error, changeset} -> Repo.rollback(changeset)
            end
        end
      end)

    case result do
      {:ok, {:unchanged, archived_threads}} ->
        Enum.each(archived_threads, &BufferEvents.direct_message_closed/1)
        :ok

      {:ok, {updated, archived_threads}} ->
        Enum.each(archived_threads, &BufferEvents.direct_message_closed/1)
        BufferEvents.direct_message_thread(updated)
        {:ok, updated}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp maybe_pause_direct_message_rename_after_lock(connection_id) do
    case Application.get_env(:ircpipe, :pause_direct_message_rename_after_lock) do
      {test_pid, pause_ref} when is_pid(test_pid) ->
        send(test_pid, {:direct_message_rename_paused, self(), pause_ref, connection_id})

        receive do
          {:continue_direct_message_rename, ^pause_ref} -> :ok
        end

      _not_paused ->
        :ok
    end
  end

  def update_connection_casemapping(%ServerConnection{} = connection, casemapping) do
    mapping = Atom.to_string(casemapping)

    connection
    |> Ecto.Changeset.change(casemapping: mapping)
    |> Repo.update()
  end

  def request_channel_join(user, %ServerConnection{} = connection, channel),
    do: request_channel_join(user, connection, channel, stored_casemapping(connection) || :ascii)

  def request_channel_join(
        %User{id: user_id} = user,
        %ServerConnection{user_id: user_id} = connection,
        channel,
        casemapping
      ) do
    channel = String.trim(channel)

    case Repo.transaction(fn ->
           losers = MembershipReconciler.reconcile_in_transaction(connection, casemapping)

           membership =
             case channel_membership(connection, channel, casemapping) do
               %ChannelMembership{} = membership ->
                 attrs =
                   if membership.status == "joined" do
                     %{auto_join: true, left_at: nil, last_error: nil}
                   else
                     %{status: "pending", auto_join: true, left_at: nil, last_error: nil}
                   end

                 membership
                 |> ChannelMembership.changeset(attrs)
                 |> Repo.update!()

               nil ->
                 %ChannelMembership{user_id: user.id, server_connection_id: connection.id}
                 |> ChannelMembership.changeset(%{
                   channel: channel,
                   status: "pending",
                   auto_join: true
                 })
                 |> Repo.insert!()
             end

           {membership, losers}
         end) do
      {:ok, {membership, losers}} ->
        MembershipReconciler.broadcast_losers(connection, losers)
        {:ok, membership}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def request_channel_join(%User{}, %ServerConnection{}, _channel, _casemapping),
    do: {:error, :invalid_connection}

  def join_channel(%User{} = user, %ServerConnection{} = connection, channel) do
    with {:ok, pending} <- request_channel_join(user, connection, channel),
         {:ok, membership} <- confirm_channel_join(connection, pending.channel) do
      {:ok, membership}
    end
  end

  def confirm_channel_join(
        %ServerConnection{} = connection,
        channel,
        casemapping \\ :rfc1459,
        connection_status \\ nil
      ) do
    now = DateTime.utc_now(:second)

    {result, broadcast?} =
      case channel_membership(connection, channel, casemapping) do
        %ChannelMembership{} = membership ->
          result =
            membership
            |> ChannelMembership.changeset(%{
              status: "joined",
              auto_join: membership.auto_join,
              joined_at: if(membership.status == "joined", do: membership.joined_at, else: now),
              left_at: nil,
              last_error: nil
            })
            |> Repo.update()

          {result, membership.status != "joined"}

        nil ->
          result =
            %ChannelMembership{user_id: connection.user_id, server_connection_id: connection.id}
            |> ChannelMembership.changeset(%{
              channel: channel,
              status: "joined",
              auto_join: false,
              joined_at: now
            })
            |> Repo.insert()

          {result, true}
      end

    with {:ok, membership} <- result do
      if broadcast?, do: BufferEvents.joined(connection, membership, connection_status)
      {:ok, membership}
    end
  end

  def reject_channel_join(
        %ServerConnection{} = connection,
        channel,
        reason,
        casemapping \\ :rfc1459
      ) do
    case channel_membership(connection, channel, casemapping) do
      %ChannelMembership{} = membership ->
        result =
          membership
          |> ChannelMembership.changeset(%{
            status: "error",
            auto_join: false,
            last_error: reason_text(reason)
          })
          |> Repo.update()

        with {:ok, rejected} <- result do
          BufferEvents.left(%{
            user_id: connection.user_id,
            buffer_id: "channel:#{rejected.id}",
            server_connection_id: connection.id,
            channel_membership_id: rejected.id,
            channel: rejected.channel
          })

          {:ok, rejected}
        end

      nil ->
        {:error, :invalid_buffer}
    end
  end

  def confirm_channel_left(%ServerConnection{} = connection, channel, casemapping \\ :rfc1459) do
    case channel_membership(connection, channel, casemapping) do
      %ChannelMembership{} = membership ->
        result =
          membership
          |> ChannelMembership.changeset(%{
            status: "left",
            auto_join: false,
            left_at:
              if(membership.status == "left",
                do: membership.left_at,
                else: DateTime.utc_now(:second)
              ),
            last_error: nil
          })
          |> Repo.update()

        with {:ok, updated} <- result do
          from(u in ChannelUser, where: u.channel_membership_id == ^updated.id)
          |> Repo.delete_all()

          if membership.status != "left" do
            BufferEvents.left(%{
              user_id: connection.user_id,
              buffer_id: "channel:#{updated.id}",
              server_connection_id: connection.id,
              channel_membership_id: updated.id
            })
          end

          {:ok, updated}
        end

      nil ->
        {:error, :invalid_buffer}
    end
  end

  def reject_channel_part(
        %ServerConnection{} = connection,
        channel,
        reason,
        casemapping \\ :rfc1459
      ) do
    case channel_membership(connection, channel, casemapping, "joined") do
      %ChannelMembership{} = membership ->
        membership
        |> ChannelMembership.changeset(%{last_error: reason_text(reason)})
        |> Repo.update()

      nil ->
        {:error, :invalid_buffer}
    end
  end

  def get_membership!(%User{id: user_id}, id) do
    ChannelMembership
    |> where([m], m.user_id == ^user_id and m.id == ^id)
    |> preload(:server_connection)
    |> Repo.one!()
  end

  def get_channel_membership(%ServerConnection{} = connection, channel, casemapping \\ :rfc1459),
    do: channel_membership(connection, channel, casemapping)

  def get_membership_by_channel!(
        %User{id: user_id},
        %ServerConnection{} = connection,
        channel,
        casemapping \\ nil
      ) do
    mapping = casemapping || stored_casemapping(connection) || :ascii

    case channel_membership(connection, channel, mapping) do
      %ChannelMembership{user_id: ^user_id} = membership ->
        Repo.preload(membership, :server_connection)

      _membership ->
        raise Ecto.NoResultsError, queryable: ChannelMembership
    end
  end

  def record_inbound_message(
        %ServerConnection{} = connection,
        channel,
        nick,
        body,
        kind \\ "message",
        metadata \\ %{},
        casemapping \\ :rfc1459
      ) do
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

  def record_server_message(
        %ServerConnection{} = connection,
        body,
        kind \\ "system",
        nick \\ nil,
        metadata \\ %{}
      ) do
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

  def record_direct_message(
        %ServerConnection{} = connection,
        peer_nick,
        nick,
        body,
        kind \\ "message",
        metadata \\ %{},
        casemapping \\ nil
      ) do
    user = Repo.get!(User, connection.user_id)
    incoming? = metadata_value(metadata, :direction) == "incoming"
    mapping = casemapping || stored_casemapping(connection) || :ascii

    result =
      Repo.transaction(fn ->
        lock_direct_message_connection!(connection.id)
        identity_keys = PeerIdentity.keys(metadata)
        blocked_thread = incoming? && blocked_direct_message_thread(connection, identity_keys)

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
                 ensure_direct_message_thread(
                   user,
                   connection,
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
                  |> direct_message_thread_changeset(%{
                    closed_at: nil,
                    unread_count: thread.unread_count + 1
                  })
                  |> Repo.update!()
                else
                  thread
                end

              message =
                %Message{
                  user_id: connection.user_id,
                  server_connection_id: connection.id,
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
        Enum.each(archived_threads, &BufferEvents.direct_message_closed/1)
        {:ok, Map.delete(recorded, :archived_threads)}

      {:ok,
       %{
         thread: thread,
         message: message,
         notification: notification,
         archived_threads: archived_threads
       } =
           recorded} ->
        Enum.each(archived_threads, &BufferEvents.direct_message_closed/1)
        if notification, do: Delivery.enqueue(notification)
        BufferEvents.direct_message_thread(thread)
        BufferEvents.direct_message(message, thread)

        {:ok, Map.delete(recorded, :archived_threads)}

      error ->
        error
    end
  end

  def record_channel_system_message(
        %ServerConnection{} = connection,
        channel,
        kind,
        nick,
        body,
        metadata \\ %{},
        casemapping \\ :rfc1459
      ) do
    membership = channel_membership(connection, channel, casemapping)

    user = Repo.get!(User, connection.user_id)

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
          metadata: stringify_metadata(metadata),
          body: body,
          mentioned: false,
          occurred_at: DateTime.utc_now(:second)
        })
        |> Repo.insert()

      Retention.prune(user)
      message
    end)
    |> case do
      {:ok, message} ->
        BufferEvents.message(message, membership, connection)
        {:ok, message}

      error ->
        error
    end
  end

  def record_command_message(
        %ServerConnection{} = connection,
        buffer_id,
        body,
        metadata
      ) do
    membership = command_membership(connection, buffer_id)
    user = Repo.get!(User, connection.user_id)

    Repo.transaction(fn ->
      {:ok, message} =
        %Message{
          user_id: connection.user_id,
          server_connection_id: connection.id,
          channel_membership_id: membership && membership.id
        }
        |> Message.changeset(%{
          kind: "command",
          nick: connection.nickname,
          metadata: stringify_metadata(metadata),
          body: body,
          mentioned: false,
          occurred_at: DateTime.utc_now(:second)
        })
        |> Repo.insert()

      Retention.prune(user)
      message
    end)
    |> case do
      {:ok, message} ->
        BufferEvents.command_message(message, membership, connection)
        {:ok, message}

      error ->
        error
    end
  end

  def update_command_message(%Message{} = message, metadata) when is_map(metadata) do
    merged_metadata = Map.merge(message.metadata || %{}, stringify_metadata(metadata))

    Repo.transaction(fn ->
      {:ok, message} =
        message
        |> Message.changeset(%{metadata: merged_metadata})
        |> Repo.update()

      connection = Repo.get!(ServerConnection, message.server_connection_id)
      membership = membership_for_message(message)
      {message, membership, connection}
    end)
    |> case do
      {:ok, {message, membership, connection}} ->
        BufferEvents.command_message(message, membership, connection)
        {:ok, message}

      error ->
        error
    end
  end

  def record_channel_system_message_all(%ServerConnection{} = connection, kind, nick, body_fun)
      when is_function(body_fun, 1) do
    connection
    |> Presence.memberships(nil)
    |> Enum.each(fn membership ->
      record_channel_system_message(
        connection,
        membership.channel,
        kind,
        nick,
        body_fun.(membership)
      )
    end)
  end

  def record_channel_system_message_for_present_nick(
        %ServerConnection{} = connection,
        kind,
        nick,
        body_fun
      )
      when is_binary(nick) and is_function(body_fun, 1) do
    record_channel_system_message_for_present_nick(connection, kind, nick, nick, body_fun)
  end

  def record_channel_system_message_for_present_nick(
        %ServerConnection{} = connection,
        kind,
        present_nick,
        message_nick,
        body_fun
      )
      when is_binary(present_nick) and is_function(body_fun, 1) do
    connection
    |> Presence.memberships_with_nick(present_nick)
    |> Enum.each(fn membership ->
      record_channel_system_message(
        connection,
        membership.channel,
        kind,
        message_nick,
        body_fun.(membership)
      )
    end)
  end

  def mark_read(%User{id: user_id}, %ChannelMembership{} = membership) do
    now = DateTime.utc_now(:second)

    Repo.transaction(fn ->
      lock_direct_message_connection!(membership.server_connection_id)

      from(m in ChannelMembership, where: m.id == ^membership.id and m.user_id == ^user_id)
      |> Repo.update_all(set: [last_read_at: now, unread_count: 0, mention_count: 0])

      from(n in Notification,
        where:
          n.user_id == ^user_id and n.channel_membership_id == ^membership.id and
            is_nil(n.read_at)
      )
      |> Repo.update_all(set: [read_at: now])
    end)

    BufferEvents.read(%{
      user_id: user_id,
      buffer_id: "channel:#{membership.id}",
      server_connection_id: membership.server_connection_id,
      channel_membership_id: membership.id
    })

    :ok
  end

  def mark_read(%User{id: user_id}, %ServerConnection{} = connection) do
    now = DateTime.utc_now(:second)

    from(c in ServerConnection, where: c.id == ^connection.id and c.user_id == ^user_id)
    |> Repo.update_all(set: [last_read_at: now, unread_count: 0, mention_count: 0])

    BufferEvents.read(%{
      user_id: user_id,
      buffer_id: "server:#{connection.id}",
      server_connection_id: connection.id,
      channel_membership_id: nil
    })

    :ok
  end

  def leave_channel(%User{id: user_id}, %ChannelMembership{} = membership) do
    if membership.user_id == user_id do
      connection = Repo.get!(ServerConnection, membership.server_connection_id)

      case confirm_channel_left(connection, membership.channel) do
        {:ok, _membership} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :invalid_buffer}
    end
  end

  defp ensure_direct_message_thread(
         %User{} = user,
         %ServerConnection{} = connection,
         peer_nick,
         metadata,
         incoming?,
         casemapping \\ nil
       ) do
    mapping = casemapping || stored_casemapping(connection) || :ascii
    peer_key = Identifier.key(peer_nick, mapping)
    identity = PeerIdentity.details(metadata)

    {thread, archived_threads} = find_direct_message_thread(connection, identity.keys, peer_key)

    thread =
      thread || %DirectMessageThread{user_id: user.id, server_connection_id: connection.id}

    reopen? = not incoming? or is_nil(thread.blocked_at)

    attrs =
      %{
        peer_nick: peer_nick,
        peer_key: peer_key,
        account: identity.account || thread.account,
        hostmask: identity.hostmask || thread.hostmask,
        identity_key: thread.identity_key || identity.primary_key
      }
      |> then(fn attrs -> if reopen?, do: Map.put(attrs, :closed_at, nil), else: attrs end)

    thread
    |> direct_message_thread_changeset(attrs)
    |> Repo.insert_or_update()
    |> case do
      {:ok, saved} -> {:ok, saved, archived_threads}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp find_direct_message_thread(connection, identity_keys, peer_key, desired_peer_key \\ nil) do
    threads =
      DirectMessageThread
      |> where([thread], thread.server_connection_id == ^connection.id)
      |> order_by([thread], desc: is_nil(thread.closed_at), desc: thread.updated_at)
      |> Repo.all()

    by_identity =
      Enum.find(threads, fn thread ->
        PeerIdentity.thread_keys(thread)
        |> Enum.any?(&(&1 in identity_keys))
      end)

    by_peer = Enum.find(threads, &(&1.peer_key == peer_key))

    desired_peer =
      if desired_peer_key, do: Enum.find(threads, &(&1.peer_key == desired_peer_key))

    cond do
      by_identity && desired_peer && by_identity.id != desired_peer.id ->
        {by_identity, [archive_direct_message_thread(desired_peer)]}

      is_nil(by_identity) && by_peer && desired_peer && by_peer.id != desired_peer.id ->
        {by_peer, [archive_direct_message_thread(desired_peer)]}

      by_identity && by_peer && by_identity.id != by_peer.id ->
        {by_identity, [archive_direct_message_thread(by_peer)]}

      by_identity ->
        {by_identity, []}

      is_nil(by_peer) ->
        {nil, []}

      identity_keys == [] or PeerIdentity.thread_keys(by_peer) == [] ->
        {by_peer, []}

      true ->
        {nil, [archive_direct_message_thread(by_peer)]}
    end
  end

  defp archive_direct_message_thread(thread) do
    archived_key = "archived:#{thread.id}:#{thread.peer_key}" |> String.slice(0, 128)
    now = DateTime.utc_now(:second)

    archived =
      thread
      |> direct_message_thread_changeset(%{
        peer_key: archived_key,
        closed_at: thread.closed_at || now,
        last_read_at: now,
        unread_count: 0
      })
      |> Repo.update!()

    mark_direct_message_notifications_read(archived.id, now)
    archived
  end

  defp archived_direct_message_thread?(thread) do
    is_binary(thread.peer_key) and String.starts_with?(thread.peer_key, "archived:")
  end

  defp direct_message_thread_changeset(%DirectMessageThread{} = thread, attrs) do
    thread
    |> DirectMessageThread.changeset(attrs)
    |> Ecto.Changeset.put_change(:mutation_revision, thread.mutation_revision + 1)
  end

  defp blocked_direct_message_thread(_connection, []), do: nil

  defp blocked_direct_message_thread(connection, identity_keys) do
    from(identity in DirectMessageBlockIdentity,
      join: thread in assoc(identity, :direct_message_thread),
      where:
        identity.server_connection_id == ^connection.id and
          identity.identity_key in ^identity_keys and not is_nil(thread.blocked_at),
      select: thread,
      limit: 1
    )
    |> Repo.one()
  end

  defp persist_direct_message_block_identities(thread) do
    now = DateTime.utc_now(:second)

    entries =
      Enum.map(PeerIdentity.thread_keys(thread), fn identity_key ->
        %{
          identity_key: identity_key,
          direct_message_thread_id: thread.id,
          server_connection_id: thread.server_connection_id,
          user_id: thread.user_id,
          inserted_at: now,
          updated_at: now
        }
      end)

    if entries != [] do
      Repo.insert_all(DirectMessageBlockIdentity, entries,
        on_conflict: :nothing,
        conflict_target: [:server_connection_id, :identity_key]
      )
    end
  end

  defp lock_direct_message_connection!(connection_id) do
    ServerConnection
    |> where([connection], connection.id == ^connection_id)
    |> lock("FOR UPDATE")
    |> Repo.one!()
  end

  defp mark_direct_message_notifications_read(thread_id, now) do
    from(notification in Notification,
      where: notification.direct_message_thread_id == ^thread_id and is_nil(notification.read_at)
    )
    |> Repo.update_all(set: [read_at: now, updated_at: now])
  end

  defp metadata_value(metadata, key) do
    Map.get(metadata, key) || Map.get(metadata, Atom.to_string(key))
  end

  defp stringify_metadata(metadata) when is_map(metadata) do
    Map.new(metadata, fn {key, value} -> {to_string(key), value} end)
  end

  defp stringify_metadata(_metadata), do: %{}

  defp reason_text(reason) when is_binary(reason), do: reason
  defp reason_text(reason), do: inspect(reason)

  defp command_membership(%ServerConnection{id: connection_id}, "channel:" <> membership_id) do
    Repo.get_by!(ChannelMembership, id: membership_id, server_connection_id: connection_id)
  end

  defp command_membership(%ServerConnection{id: connection_id}, "server:" <> connection_id_text)
       when is_binary(connection_id_text) do
    if Integer.to_string(connection_id) == connection_id_text,
      do: nil,
      else: raise(Ecto.NoResultsError, queryable: ServerConnection)
  end

  defp command_membership(%ServerConnection{}, _buffer_id),
    do: raise(Ecto.NoResultsError, queryable: ChannelMembership)

  defp membership_for_message(%Message{channel_membership_id: nil}), do: nil

  defp membership_for_message(%Message{channel_membership_id: membership_id}),
    do: Repo.get!(ChannelMembership, membership_id)

  defp channel_membership(connection, channel, casemapping, status \\ nil) do
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

  defp stored_casemapping(%ServerConnection{casemapping: mapping}) when is_binary(mapping) do
    case mapping do
      "ascii" -> :ascii
      "strict_rfc1459" -> :strict_rfc1459
      _mapping -> :rfc1459
    end
  end

  defp stored_casemapping(%ServerConnection{}), do: nil
end
