defmodule Ircpipe.Chat.ConnectionEndpoint do
  @moduledoc false

  import Ecto.Query

  alias Ircpipe.Accounts.User
  alias Ircpipe.Chat.{ConnectionAttributes, ServerConnection}
  alias Ircpipe.Repo

  def create(%User{} = user, attrs) do
    attrs = ConnectionAttributes.prepare(attrs, user)

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
      host = ConnectionAttributes.normalize_host_value(host)

      attrs =
        attrs
        |> ConnectionAttributes.put(:host, host)
        |> ConnectionAttributes.put(:port, port)

      create_or_get_locked(user, attrs, host, port)
    else
      _invalid_endpoint -> create(user, attrs)
    end
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

  defp maybe_pause_endpoint_create(user_id, host, port) do
    case Application.get_env(:ircpipe_web, :connection_endpoint_create_barrier) do
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
    case Application.get_env(:ircpipe_web, :connection_endpoint_create_barrier) do
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
end
