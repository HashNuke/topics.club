defmodule Ircpipe.Chat.Connections do
  @moduledoc false

  import Ecto.Query

  alias Ircpipe.Accounts.User

  alias Ircpipe.Chat.{
    ConnectionDeletionEventBatch,
    ConnectionDeletionEventsWorker,
    ChannelMembership,
    ConnectionDeletionWorker,
    DirectMessageThread,
    MembershipReconciler,
    ServerConnection
  }

  alias Ircpipe.Irc.ConnectionLock
  alias Ircpipe.Irc.SessionSupervisor
  alias Ircpipe.Repo

  def list(%User{} = user) do
    user |> snapshot() |> Map.fetch!(:connections)
  end

  def snapshot(%User{} = user) do
    if Repo.in_transaction?() do
      raise ArgumentError,
            "snapshot cannot own a nested transaction; use snapshot_in_transaction and broadcast after the transaction commits"
    end

    {:ok, internal_snapshot} = Repo.transaction(fn -> snapshot_in_transaction(user) end)
    broadcast_reconciliations(internal_snapshot.reconciliations)
    public_snapshot(internal_snapshot)
  end

  def snapshot_in_transaction(%User{id: user_id}) do
    unless Repo.in_transaction?() do
      raise ArgumentError,
            "connection snapshots with deferred events require a database transaction"
    end

    connections =
      ServerConnection
      |> where([connection], connection.user_id == ^user_id and not connection.deleting)
      |> order_by([connection], asc: connection.inserted_at, asc: connection.id)
      |> Repo.all()

    reconciliations =
      Enum.flat_map(connections, fn connection ->
        case stored_casemapping(connection) do
          nil ->
            []

          mapping ->
            case MembershipReconciler.reconcile_in_transaction(connection, mapping) do
              [] -> []
              losers -> [{connection, losers}]
            end
        end
      end)

    memberships =
      from(membership in ChannelMembership,
        order_by: [asc: fragment("lower(?)", membership.channel), asc: membership.id]
      )

    connections = Repo.preload(connections, [channel_memberships: memberships], force: true)

    direct_message_threads =
      DirectMessageThread
      |> join(:inner, [thread], connection in ServerConnection,
        on: connection.id == thread.server_connection_id
      )
      |> where([thread, connection], thread.user_id == ^user_id and not connection.deleting)
      |> order_by([thread], asc: fragment("lower(?)", thread.peer_nick), asc: thread.id)
      |> Repo.all()

    open_threads_by_connection =
      direct_message_threads
      |> Enum.reject(& &1.closed_at)
      |> Enum.group_by(& &1.server_connection_id)

    connections =
      Enum.map(connections, fn connection ->
        %{
          connection
          | direct_message_threads: Map.get(open_threads_by_connection, connection.id, [])
        }
      end)

    tombstones =
      direct_message_threads
      |> Enum.filter(& &1.closed_at)
      |> Enum.sort_by(& &1.id)
      |> Enum.map(fn thread ->
        %{
          buffer_id: "direct:#{thread.id}",
          server_connection_id: thread.server_connection_id,
          direct_message_thread_id: thread.id,
          revision: thread.mutation_revision
        }
      end)

    %{
      connections: connections,
      direct_message_tombstones: tombstones,
      reconciliations: reconciliations
    }
  end

  def broadcast_reconciliations(reconciliations) when is_list(reconciliations) do
    if Repo.in_transaction?() do
      raise ArgumentError, "reconciliation events must be broadcast after the transaction commits"
    end

    Enum.each(reconciliations, fn {connection, losers} ->
      MembershipReconciler.broadcast_losers(connection, losers)
    end)
  end

  def create(%User{} = user, attrs) do
    attrs = attrs |> normalize_host() |> connection_defaults(user)

    %ServerConnection{user_id: user.id}
    |> ServerConnection.changeset(attrs)
    |> Repo.insert()
  end

  def create_or_get(%User{} = user, attrs) do
    host = Map.get(attrs, "host") || Map.get(attrs, :host)
    requested_port = Map.get(attrs, "port") || Map.get(attrs, :port) || 6697

    with true <- is_binary(host),
         {:ok, port} when port > 0 and port < 65_536 <-
           Ecto.Type.cast(:integer, requested_port) do
      host = normalize_host_value(host)

      attrs =
        attrs
        |> put_attr(:host, host)
        |> put_attr(:port, port)

      create_or_get_locked(user, attrs, host, port)
    else
      _invalid_endpoint -> create(user, attrs)
    end
  end

  def get!(%User{id: user_id}, id) do
    ServerConnection
    |> where(
      [connection],
      connection.user_id == ^user_id and connection.id == ^id and not connection.deleting
    )
    |> preload(:channel_memberships)
    |> Repo.one!()
  end

  def update(%User{} = user, id, attrs) do
    user
    |> get!(id)
    |> ServerConnection.changeset(normalize_host(attrs))
    |> Repo.update()
  end

  def delete(%User{} = user, id) do
    if Repo.in_transaction?() do
      raise ArgumentError,
            "cannot delete inside an existing transaction because buffer events must follow commit"
    end

    {:ok, id} = Ecto.Type.cast(:id, id)

    with %ServerConnection{} = connection <- mark_deleting(user, id),
         :ok <- maybe_pause_delete_after_mark(connection) do
      case finalize_deletion(user.id, id) do
        :ok -> {:ok, connection}
        result -> result
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def finalize_deletion(user_id, id) when is_integer(user_id) and is_integer(id) do
    if Repo.in_transaction?() do
      raise ArgumentError,
            "cannot finalize deletion inside an existing transaction because buffer events must follow commit"
    end

    case deleting_connection(user_id, id) do
      nil ->
        :ok

      %ServerConnection{} = connection ->
        with :ok <- SessionSupervisor.stop_for_deletion(connection),
             {:ok, result} <- Repo.transaction(fn -> delete_in_transaction(user_id, id) end) do
          case result do
            :already_deleted ->
              :ok

            {deleted, event_batch, event_job} ->
              maybe_pause_delete_after_commit(event_batch)
              :ok = ConnectionDeletionEventsWorker.dispatch(event_batch.id)
              :ok = Oban.cancel_job(event_job)
              {:ok, deleted}
          end
        end
    end
  end

  defp mark_deleting(user, id) do
    ConnectionLock.run(user, id, fn ->
      connection =
        ServerConnection
        |> where([connection], connection.user_id == ^user.id and connection.id == ^id)
        |> Repo.one!()

      connection
      |> Ecto.Changeset.change(deleting: true)
      |> Repo.update!()
      |> tap(fn marked_connection ->
        %{user_id: marked_connection.user_id, connection_id: marked_connection.id}
        |> ConnectionDeletionWorker.new()
        |> Oban.insert!()
      end)
    end)
  end

  defp deleting_connection(user_id, id) do
    ServerConnection
    |> where(
      [connection],
      connection.user_id == ^user_id and connection.id == ^id and connection.deleting
    )
    |> Repo.one()
  end

  defp maybe_pause_delete_after_mark(connection) do
    case Application.get_env(:ircpipe, :connection_delete_after_mark_barrier) do
      {test_pid, barrier_ref} when is_pid(test_pid) ->
        test_ref = Process.monitor(test_pid)
        send(test_pid, {:connection_delete_marked, self(), barrier_ref, connection.id})

        receive do
          {:continue_marked_connection_delete, ^barrier_ref} ->
            Process.demonitor(test_ref, [:flush])
            :ok

          {:DOWN, ^test_ref, :process, ^test_pid, _reason} ->
            :ok
        end

      _not_paused ->
        :ok
    end
  end

  def default_nick(%User{email: email}) do
    base =
      email
      |> String.split("@")
      |> List.first()
      |> String.replace(~r/[^A-Za-z0-9_\-\[\]\\`^{}]/, "_")
      |> String.trim("_-")

    base =
      cond do
        base == "" -> "topics_user"
        String.match?(String.first(base), ~r/^[A-Za-z_\[\]\\`^{}]$/) -> base
        true -> "u_#{base}"
      end

    String.slice(base, 0, 24)
  end

  defp create_or_get_locked(user, attrs, host, port) do
    maybe_wait_for_endpoint_lock(user.id, host, port)

    {:ok, result} =
      Repo.transaction(fn ->
        lock_user!(user.id)

        case find_by_endpoint(user, host, port) do
          %ServerConnection{} = connection ->
            {:ok, connection}

          _missing ->
            maybe_pause_endpoint_create(user.id, host, port)
            create(user, attrs)
        end
      end)

    result
  end

  defp delete_in_transaction(user_id, id) do
    case ServerConnection
         |> where(
           [connection],
           connection.user_id == ^user_id and connection.id == ^id and connection.deleting
         )
         |> lock("FOR UPDATE")
         |> Repo.one() do
      nil ->
        :already_deleted

      %ServerConnection{} = connection ->
        delete_locked_connection(connection)
    end
  end

  defp delete_locked_connection(connection) do
    connection = Repo.preload(connection, :channel_memberships, force: true)
    maybe_pause_delete_after_lock(connection)
    maybe_fail_final_delete(connection)

    case Repo.delete(connection) do
      {:ok, deleted} ->
        event_batch = insert_event_batch!(connection)

        event_job =
          %{event_batch_id: event_batch.id}
          |> ConnectionDeletionEventsWorker.new(scheduled_in: {1, :minute})
          |> Oban.insert!()

        {deleted, event_batch, event_job}

      {:error, changeset} ->
        Repo.rollback(changeset)
    end
  end

  defp insert_event_batch!(connection) do
    occurred_at = DateTime.utc_now(:second)

    payloads =
      connection
      |> deleted_buffer_payloads()
      |> Enum.map(fn payload ->
        payload
        |> Map.drop([:user_id])
        |> Map.put(:event_id, "connection_deletion:#{connection.id}:#{payload.buffer_id}")
        |> Map.put(:occurred_at, DateTime.to_iso8601(occurred_at))
      end)

    %ConnectionDeletionEventBatch{
      user_id: connection.user_id,
      server_connection_id: connection.id,
      payloads: %{events: payloads}
    }
    |> Repo.insert!()
  end

  defp maybe_fail_final_delete(connection) do
    maybe_raise_final_delete(connection)

    case Application.get_env(:ircpipe, :connection_final_delete_failure) do
      {test_pid, failure_ref} when is_pid(test_pid) ->
        send(test_pid, {:connection_final_delete_failed, self(), failure_ref, connection.id})
        Repo.rollback(:forced_final_delete_failure)

      _no_failure ->
        :ok
    end
  end

  defp maybe_raise_final_delete(connection) do
    case Application.get_env(:ircpipe, :connection_final_delete_exception) do
      {test_pid, exception_ref} when is_pid(test_pid) ->
        send(test_pid, {:connection_final_delete_raised, self(), exception_ref, connection.id})
        raise "forced connection final-delete exception"

      _no_exception ->
        :ok
    end
  end

  defp maybe_pause_delete_after_commit(event_batch) do
    case Application.get_env(:ircpipe, :connection_delete_after_commit_barrier) do
      {test_pid, barrier_ref} when is_pid(test_pid) ->
        test_ref = Process.monitor(test_pid)
        send(test_pid, {:connection_delete_committed, self(), barrier_ref, event_batch.id})

        receive do
          {:continue_connection_delete_after_commit, ^barrier_ref} ->
            Process.demonitor(test_ref, [:flush])
            :ok

          {:DOWN, ^test_ref, :process, ^test_pid, _reason} ->
            :ok
        end

      _not_paused ->
        :ok
    end
  end

  defp maybe_pause_delete_after_lock(connection) do
    case Application.get_env(:ircpipe, :connection_delete_after_lock_barrier) do
      {test_pid, barrier_ref} when is_pid(test_pid) ->
        test_ref = Process.monitor(test_pid)
        send(test_pid, {:connection_delete_paused, self(), barrier_ref, connection.id})

        receive do
          {:continue_connection_delete, ^barrier_ref} ->
            Process.demonitor(test_ref, [:flush])
            :ok

          {:DOWN, ^test_ref, :process, ^test_pid, _reason} ->
            :ok
        end

      _not_paused ->
        :ok
    end
  end

  defp deleted_buffer_payloads(connection) do
    channel_payloads =
      connection.channel_memberships
      |> Enum.sort_by(& &1.id)
      |> Enum.map(fn membership ->
        %{
          user_id: connection.user_id,
          buffer_id: "channel:#{membership.id}",
          server_connection_id: connection.id,
          channel_membership_id: membership.id
        }
      end)

    channel_payloads ++
      [
        %{
          user_id: connection.user_id,
          buffer_id: "server:#{connection.id}",
          server_connection_id: connection.id,
          channel_membership_id: nil
        }
      ]
  end

  defp lock_user!(user_id) do
    User
    |> where([user], user.id == ^user_id)
    |> select([user], user.id)
    |> lock("FOR UPDATE")
    |> Repo.one!()
  end

  defp find_by_endpoint(%User{id: user_id}, host, port) do
    ServerConnection
    |> where(
      [connection],
      connection.user_id == ^user_id and connection.port == ^port and
        not connection.deleting and
        fragment("lower(btrim(?))", connection.host) == ^host
    )
    |> order_by([connection], asc: connection.inserted_at, asc: connection.id)
    |> limit(1)
    |> Repo.one()
  end

  defp normalize_host(attrs) do
    host = Map.get(attrs, "host") || Map.get(attrs, :host)

    if is_binary(host) do
      put_attr(attrs, :host, normalize_host_value(host))
    else
      attrs
    end
  end

  defp normalize_host_value(host) do
    host |> String.trim() |> String.downcase()
  end

  defp maybe_pause_endpoint_create(user_id, host, port) do
    case Application.get_env(:ircpipe, :connection_endpoint_create_barrier) do
      {test_pid, barrier_ref} when is_pid(test_pid) ->
        send(
          test_pid,
          {:connection_endpoint_create_paused, self(), barrier_ref, user_id, host, port}
        )

        receive do
          {:continue_connection_endpoint_create, ^barrier_ref} -> :ok
        end

      _no_barrier ->
        :ok
    end
  end

  defp maybe_wait_for_endpoint_lock(user_id, host, port) do
    case Application.get_env(:ircpipe, :connection_endpoint_create_barrier) do
      {test_pid, barrier_ref} when is_pid(test_pid) ->
        send(
          test_pid,
          {:connection_endpoint_lock_ready, self(), barrier_ref, user_id, host, port}
        )

        receive do
          {:start_connection_endpoint_lock, ^barrier_ref} -> :ok
        end

      _no_barrier ->
        :ok
    end
  end

  defp connection_defaults(attrs, user) do
    nickname = present_attr(attrs, :nickname) || default_nick(user)

    attrs
    |> put_attr(:nickname, nickname)
    |> maybe_put_sasl_username(nickname)
  end

  defp maybe_put_sasl_username(attrs, nickname) do
    if present_attr(attrs, :sasl_password) && !present_attr(attrs, :sasl_username) do
      put_attr(attrs, :sasl_username, nickname)
    else
      attrs
    end
  end

  defp present_attr(attrs, key) do
    value = Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
    if is_binary(value) && String.trim(value) != "", do: String.trim(value)
  end

  defp put_attr(attrs, key, value) do
    cond do
      Map.has_key?(attrs, key) -> Map.put(attrs, key, value)
      Map.has_key?(attrs, Atom.to_string(key)) -> Map.put(attrs, Atom.to_string(key), value)
      Enum.any?(Map.keys(attrs), &is_atom/1) -> Map.put(attrs, key, value)
      true -> Map.put(attrs, Atom.to_string(key), value)
    end
  end

  defp public_snapshot(snapshot) do
    Map.take(snapshot, [:connections, :direct_message_tombstones])
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
