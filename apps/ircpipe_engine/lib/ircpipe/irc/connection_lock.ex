defmodule Ircpipe.Irc.ConnectionLock do
  @moduledoc false

  alias Ircpipe.Accounts.User
  alias Ircpipe.Chat.ServerConnection
  alias Ircpipe.Irc.ConnectionOperationLock
  alias Ircpipe.Irc.SingleNodeGuard
  alias Ircpipe.Repo

  def run(%ServerConnection{user_id: user_id, id: connection_id}, callback) do
    run(user_id, connection_id, callback)
  end

  def run(%User{id: user_id}, connection_id, callback) do
    run(user_id, connection_id, callback)
  end

  def run(user_id, connection_id, callback)
      when is_integer(user_id) and is_integer(connection_id) and is_function(callback, 0) do
    with :ok <- SingleNodeGuard.ensure_single_node() do
      serialize_locally(user_id, connection_id, fn ->
        case Repo.transaction(fn ->
               acquire(user_id, connection_id)
               run_if_single_node(callback)
             end) do
          {:ok, result} -> result
          {:error, reason} -> {:error, reason}
        end
      end)
    end
  end

  def run_serialized(%ServerConnection{user_id: user_id, id: connection_id}, callback) do
    run_serialized(user_id, connection_id, callback)
  end

  def run_serialized(%User{id: user_id}, connection_id, callback) do
    run_serialized(user_id, connection_id, callback)
  end

  def run_serialized(user_id, connection_id, callback)
      when is_integer(user_id) and is_integer(connection_id) and is_function(callback, 0) do
    with :ok <- SingleNodeGuard.ensure_single_node() do
      serialize_locally(user_id, connection_id, fn -> run_if_single_node(callback) end)
    end
  end

  defp acquire(user_id, connection_id) do
    lock_key = advisory_lock_key(user_id, connection_id)
    _result = Repo.query!("SELECT pg_advisory_xact_lock($1)", [lock_key])
    :ok
  end

  defp advisory_lock_key(user_id, connection_id) do
    lock_identity = :erlang.term_to_binary({__MODULE__, user_id, connection_id})
    <<lock_key::signed-integer-size(64), _rest::binary>> = :crypto.hash(:sha256, lock_identity)
    lock_key
  end

  defp serialize_locally(user_id, connection_id, callback) do
    ConnectionOperationLock.run(user_id, connection_id, callback)
  end

  defp run_if_single_node(callback) do
    with :ok <- SingleNodeGuard.ensure_single_node(), do: callback.()
  end
end
