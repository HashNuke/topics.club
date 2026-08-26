defmodule Ircpipe.Chat.ConnectionActivity do
  @moduledoc false

  import Ecto.Query

  alias Ircpipe.Accounts.User
  alias Ircpipe.Chat.ServerConnection
  alias Ircpipe.Repo

  def recently_seen(cutoff) do
    ServerConnection
    |> join(:inner, [connection], user in User, on: user.id == connection.user_id)
    |> where(
      [_connection, user],
      not is_nil(user.last_seen_at) and user.last_seen_at >= ^cutoff
    )
    |> preload(:channel_memberships)
    |> order_by([connection], asc: connection.user_id, asc: connection.name)
    |> Repo.all()
  end

  def inactive(cutoff) do
    ServerConnection
    |> join(:inner, [connection], user in User, on: user.id == connection.user_id)
    |> where([_connection, user], is_nil(user.last_seen_at) or user.last_seen_at < ^cutoff)
    |> preload(:channel_memberships)
    |> order_by([connection], asc: connection.user_id, asc: connection.name)
    |> Repo.all()
  end
end
