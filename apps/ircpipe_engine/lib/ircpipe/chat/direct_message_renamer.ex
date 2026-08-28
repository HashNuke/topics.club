defmodule Ircpipe.Chat.DirectMessageRenamer do
  @moduledoc false

  alias Ircpipe.Chat.{
    BufferEvents,
    DirectMessageStore,
    PeerIdentity,
    ServerConnection,
    ServerConnectionLock
  }

  alias Ircpipe.Irc.Identifier
  alias Ircpipe.Repo

  def rename(
        %ServerConnection{} = connection,
        old_nick,
        new_nick,
        metadata \\ %{},
        casemapping \\ nil
      ) do
    assert_no_outer_transaction!()

    result =
      Repo.transaction(fn ->
        active_connection = ServerConnectionLock.lock_active!(connection.id)
        maybe_pause_after_lock(connection.id)
        mapping = casemapping || stored_casemapping(active_connection) || :ascii
        old_key = Identifier.key(old_nick, mapping)
        new_key = Identifier.key(new_nick, mapping)
        identity = PeerIdentity.details(metadata)

        case DirectMessageStore.find_thread(active_connection, identity.keys, old_key, new_key) do
          {nil, archived_threads} ->
            {:unchanged, archived_threads}

          {thread, archived_threads} ->
            case thread
                 |> DirectMessageStore.changeset(%{
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
        _effects =
          ServerConnectionLock.serialize_effects(connection.id, fn _active_connection ->
            Enum.each(archived_threads, &BufferEvents.direct_message_closed/1)
          end)

        :ok

      {:ok, {updated, archived_threads}} ->
        _effects =
          ServerConnectionLock.serialize_effects(connection.id, fn _active_connection ->
            Enum.each(archived_threads, &BufferEvents.direct_message_closed/1)
            BufferEvents.direct_message_thread(updated)
          end)

        {:ok, updated}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp maybe_pause_after_lock(connection_id) do
    case Application.get_env(:ircpipe_engine, :pause_direct_message_rename_after_lock) do
      {test_pid, pause_ref} when is_pid(test_pid) ->
        send(test_pid, {:direct_message_rename_paused, self(), pause_ref, connection_id})

        receive do
          {:continue_direct_message_rename, ^pause_ref} -> :ok
        end

      _not_paused ->
        :ok
    end
  end

  defp stored_casemapping(%ServerConnection{casemapping: mapping}) when is_binary(mapping) do
    case mapping do
      "ascii" -> :ascii
      "strict_rfc1459" -> :strict_rfc1459
      _mapping -> :rfc1459
    end
  end

  defp stored_casemapping(%ServerConnection{}), do: nil

  defp assert_no_outer_transaction! do
    if Repo.in_transaction?() do
      raise ArgumentError, "cannot rename direct messages inside an existing transaction"
    end
  end
end
