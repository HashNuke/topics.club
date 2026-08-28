defmodule TopicsClub.Chat.PresenceMembershipLookup do
  @moduledoc false

  import Ecto.Query

  alias TopicsClub.Chat.{ChannelMembership, ChannelUser, ServerConnection}
  alias TopicsClub.Irc.Identifier
  alias TopicsClub.Repo

  def list(%ServerConnection{} = connection, nil, _casemapping) do
    ChannelMembership
    |> where(
      [membership],
      membership.server_connection_id == ^connection.id and membership.status == "joined"
    )
    |> Repo.all()
  end

  def list(%ServerConnection{} = connection, channel, casemapping) do
    case find(connection, channel, casemapping, "joined") do
      %ChannelMembership{} = membership -> [membership]
      nil -> []
    end
  end

  def with_nick(%ServerConnection{} = connection, nick, casemapping) do
    nick_key = Identifier.key(nick, casemapping)

    ChannelMembership
    |> join(:inner, [membership], user in ChannelUser,
      on: user.channel_membership_id == membership.id
    )
    |> where(
      [membership, user],
      membership.server_connection_id == ^connection.id and membership.status == "joined" and
        user.nick_key == ^nick_key
    )
    |> Repo.all()
  end

  def find(%ServerConnection{} = connection, channel, casemapping, status \\ nil) do
    query =
      from(membership in ChannelMembership,
        where: membership.server_connection_id == ^connection.id
      )

    query = if status, do: where(query, [membership], membership.status == ^status), else: query
    key = Identifier.key(channel, casemapping)

    query
    |> Repo.all()
    |> Enum.find(&(Identifier.key(&1.channel, casemapping) == key))
  end
end
