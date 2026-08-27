defmodule Ircpipe.Chat.DirectMessageLifecycle do
  @moduledoc false

  import Ecto.Query

  alias Ircpipe.Accounts.{Scope, User}

  alias Ircpipe.Chat.{
    BufferEvents,
    DirectMessageBlockIdentity,
    DirectMessageStore,
    ServerConnection,
    ServerConnectionLock
  }

  alias Ircpipe.Irc.Identifier
  alias Ircpipe.Repo

  def list(%User{} = user, %ServerConnection{} = connection),
    do: DirectMessageStore.list_open(user, connection)

  def get!(%User{} = user, id), do: DirectMessageStore.get!(user, id)

  def open(
        %User{id: user_id} = user,
        %ServerConnection{user_id: user_id} = connection,
        peer_nick
      ) do
    assert_transaction_owner!()

    if Identifier.valid_nick?(peer_nick) do
      Repo.transaction(fn ->
        active_connection = ServerConnectionLock.lock_active!(connection.id)

        case DirectMessageStore.ensure_thread(user, active_connection, peer_nick, %{}, false) do
          {:ok, thread, archived_threads} -> {thread, archived_threads}
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)
      |> case do
        {:ok, {thread, archived_threads}} ->
          publish(connection.id, fn ->
            Enum.each(archived_threads, &BufferEvents.direct_message_closed/1)
          end)

          {:ok, thread}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :invalid_nick}
    end
  end

  def close(%Scope{user: user}, id) do
    assert_transaction_owner!()
    now = DateTime.utc_now(:second)

    result =
      Repo.transaction(fn ->
        candidate = get!(user, id)
        ServerConnectionLock.lock_active!(candidate.server_connection_id)
        thread = get!(user, id)

        updated =
          thread
          |> DirectMessageStore.changeset(%{
            closed_at: now,
            last_read_at: now,
            unread_count: 0
          })
          |> Repo.update!()

        DirectMessageStore.mark_notifications_read(thread.id, now)
        {updated, thread.server_connection_id}
      end)

    case result do
      {:ok, {closed, connection_id}} ->
        publish(connection_id, fn -> BufferEvents.direct_message_closed(closed) end)
        {:ok, closed}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def set_blocked(%Scope{user: user}, id, blocked?) when is_boolean(blocked?) do
    assert_transaction_owner!()
    now = DateTime.utc_now(:second)

    result =
      Repo.transaction(fn ->
        candidate = get!(user, id)
        ServerConnectionLock.lock_active!(candidate.server_connection_id)
        thread = get!(user, id)
        maybe_pause_block_after_lock(thread)

        if DirectMessageStore.archived?(thread) do
          {:closed, thread, thread.server_connection_id}
        else
          attrs =
            if blocked? do
              %{blocked_at: now, last_read_at: now, unread_count: 0}
            else
              %{blocked_at: nil}
            end

          updated = thread |> DirectMessageStore.changeset(attrs) |> Repo.update!()

          if blocked? do
            DirectMessageStore.persist_block_identities(updated)
            DirectMessageStore.mark_notifications_read(updated.id, now)
          else
            from(identity in DirectMessageBlockIdentity,
              where: identity.direct_message_thread_id == ^updated.id
            )
            |> Repo.delete_all()
          end

          {:updated, updated, updated.server_connection_id}
        end
      end)

    case result do
      {:ok, {:updated, updated, connection_id}} ->
        publish(connection_id, fn -> BufferEvents.direct_message_thread(updated) end)
        {:ok, updated}

      {:ok, {:closed, closed, connection_id}} ->
        publish(connection_id, fn -> BufferEvents.direct_message_closed(closed) end)
        {:error, :direct_message_closed}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def mark_read(%Scope{user: user}, id) do
    assert_transaction_owner!()
    now = DateTime.utc_now(:second)

    result =
      Repo.transaction(fn ->
        candidate = get!(user, id)
        ServerConnectionLock.lock_active!(candidate.server_connection_id)
        thread = get!(user, id)

        if DirectMessageStore.archived?(thread) or not is_nil(thread.closed_at) do
          Repo.rollback(:direct_message_closed)
        end

        updated =
          thread
          |> DirectMessageStore.changeset(%{last_read_at: now, unread_count: 0})
          |> Repo.update!()

        DirectMessageStore.mark_notifications_read(updated.id, now)
        {updated, updated.server_connection_id}
      end)

    case result do
      {:ok, {updated, connection_id}} ->
        publish(connection_id, fn -> BufferEvents.direct_message_thread(updated) end)
        {:ok, updated}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp publish(connection_id, callback) do
    _effects =
      ServerConnectionLock.serialize_effects(connection_id, fn _connection -> callback.() end)

    :ok
  end

  defp assert_transaction_owner! do
    if Repo.in_transaction?() do
      raise ArgumentError, "cannot mutate direct messages inside an existing transaction"
    end
  end

  defp maybe_pause_block_after_lock(thread) do
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
end
