defmodule Ircpipe.Chat.DirectMessageStore do
  @moduledoc false

  import Ecto.Query

  alias Ircpipe.Accounts.User

  alias Ircpipe.Chat.{
    DirectMessageBlockIdentity,
    DirectMessageThread,
    Notification,
    PeerIdentity,
    ServerConnection
  }

  alias Ircpipe.Irc.Identifier
  alias Ircpipe.Repo

  def list_open(
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

  def get!(%User{id: user_id}, id) do
    DirectMessageThread
    |> where([thread], thread.id == ^id and thread.user_id == ^user_id)
    |> preload(:server_connection)
    |> Repo.one!()
  end

  def ensure_thread(
        %User{id: user_id} = user,
        %ServerConnection{user_id: user_id} = connection,
        peer_nick,
        metadata,
        incoming?,
        casemapping \\ nil
      ) do
    assert_transaction!()
    mapping = casemapping || stored_casemapping(connection) || :ascii
    peer_key = Identifier.key(peer_nick, mapping)
    identity = PeerIdentity.details(metadata)

    {thread, archived_threads} = find_thread(connection, identity.keys, peer_key)
    thread = thread || %DirectMessageThread{user_id: user.id, server_connection_id: connection.id}
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
    |> changeset(attrs)
    |> Repo.insert_or_update()
    |> case do
      {:ok, saved} -> {:ok, saved, archived_threads}
      {:error, changeset} -> {:error, changeset}
    end
  end

  def find_thread(
        %ServerConnection{id: connection_id, user_id: user_id},
        identity_keys,
        peer_key,
        desired_peer_key \\ nil
      ) do
    assert_transaction!()

    threads =
      DirectMessageThread
      |> where(
        [thread],
        thread.server_connection_id == ^connection_id and thread.user_id == ^user_id
      )
      |> order_by([thread], desc: is_nil(thread.closed_at), desc: thread.updated_at)
      |> Repo.all()

    by_identity =
      Enum.find(threads, fn thread ->
        thread
        |> PeerIdentity.thread_keys()
        |> Enum.any?(&(&1 in identity_keys))
      end)

    by_peer = Enum.find(threads, &(&1.peer_key == peer_key))
    desired_peer = if desired_peer_key, do: Enum.find(threads, &(&1.peer_key == desired_peer_key))

    cond do
      by_identity && desired_peer && by_identity.id != desired_peer.id ->
        {by_identity, [archive(desired_peer)]}

      is_nil(by_identity) && by_peer && desired_peer && by_peer.id != desired_peer.id ->
        {by_peer, [archive(desired_peer)]}

      by_identity && by_peer && by_identity.id != by_peer.id ->
        {by_identity, [archive(by_peer)]}

      by_identity ->
        {by_identity, []}

      is_nil(by_peer) ->
        {nil, []}

      identity_keys == [] or PeerIdentity.thread_keys(by_peer) == [] ->
        {by_peer, []}

      true ->
        {nil, [archive(by_peer)]}
    end
  end

  def archive(thread) do
    assert_transaction!()
    archived_key = "archived:#{thread.id}:#{thread.peer_key}" |> String.slice(0, 128)
    now = DateTime.utc_now(:second)

    archived =
      thread
      |> changeset(%{
        peer_key: archived_key,
        closed_at: thread.closed_at || now,
        last_read_at: now,
        unread_count: 0
      })
      |> Repo.update!()

    mark_notifications_read(archived.id, now)
    archived
  end

  def archived?(thread) do
    is_binary(thread.peer_key) and String.starts_with?(thread.peer_key, "archived:")
  end

  def changeset(%DirectMessageThread{} = thread, attrs) do
    thread
    |> DirectMessageThread.changeset(attrs)
    |> Ecto.Changeset.put_change(:mutation_revision, thread.mutation_revision + 1)
  end

  def blocked_thread(_connection, []), do: nil

  def blocked_thread(connection, identity_keys) do
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

  def persist_block_identities(thread) do
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

  def mark_notifications_read(thread_id, now) do
    from(notification in Notification,
      where: notification.direct_message_thread_id == ^thread_id and is_nil(notification.read_at)
    )
    |> Repo.update_all(set: [read_at: now, updated_at: now])
  end

  defp stored_casemapping(%ServerConnection{casemapping: mapping}) when is_binary(mapping) do
    case mapping do
      "ascii" -> :ascii
      "strict_rfc1459" -> :strict_rfc1459
      _mapping -> :rfc1459
    end
  end

  defp stored_casemapping(%ServerConnection{}), do: nil

  defp assert_transaction! do
    unless Repo.in_transaction?() do
      raise ArgumentError, "direct-message store mutations require an active database transaction"
    end
  end
end
