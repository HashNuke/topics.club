defmodule TopicsClub.Chat.ConnectionActivity do
  @moduledoc false

  import Ecto.Query

  alias TopicsClub.Accounts.User
  alias TopicsClub.Chat.ServerConnection
  alias TopicsClub.Repo

  def recently_seen(cutoff) do
    ServerConnection
    |> join(:inner, [connection], user in User, on: user.id == connection.user_id)
    |> where(
      [connection, user],
      connection.desired_state == "connected" and not is_nil(user.last_seen_at) and
        user.last_seen_at >= ^cutoff
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
