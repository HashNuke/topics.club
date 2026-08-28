defmodule Ircpipe.Chat.ConnectionSnapshot do
  @moduledoc false

  import Ecto.Query

  alias Ircpipe.Accounts.User

  alias Ircpipe.Chat.{
    ChannelMembership,
    DirectMessageThread,
    ServerConnection
  }

  alias Ircpipe.Repo

  def list(%User{} = user) do
    user |> capture() |> Map.fetch!(:connections)
  end

  def capture(%User{} = user) do
    if Repo.in_transaction?() do
      raise ArgumentError,
            "snapshot cannot own a nested transaction; use capture_in_transaction and broadcast after the transaction commits"
    end

    {:ok, snapshot} = Repo.transaction(fn -> capture_in_transaction(user) end)
    snapshot
  end

  def capture_in_transaction(%User{id: user_id}) do
    unless Repo.in_transaction?() do
      raise ArgumentError,
            "connection snapshots with deferred events require a database transaction"
    end

    connections =
      ServerConnection
      |> where([connection], connection.user_id == ^user_id and not connection.deleting)
      |> order_by([connection], asc: connection.inserted_at, asc: connection.id)
      |> Repo.all()

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
      direct_message_tombstones: tombstones
    }
  end
end
