defmodule TopicsClub.Chat.PresenceQueries do
  @moduledoc false

  import Ecto.Query

  alias TopicsClub.Chat.{ChannelMembership, ChannelUser}
  alias TopicsClub.Repo

  def list_users(%ChannelMembership{id: membership_id}) do
    ChannelUser
    |> where([user], user.channel_membership_id == ^membership_id)
    |> order_by([user], asc: user.nick)
    |> Repo.all()
    |> Enum.map(&user_json/1)
  end

  defp user_json(%ChannelUser{} = user) do
    %{
      nick: user.nick,
      nick_key: user.nick_key,
      role: user.role,
      status: user.status,
      hostmask: user.hostmask,
      last_observed_at: user.last_observed_at
    }
  end
end
