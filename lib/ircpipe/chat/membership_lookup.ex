defmodule Ircpipe.Chat.MembershipLookup do
  import Ecto.Query

  alias Ircpipe.Accounts.User
  alias Ircpipe.Chat.{ChannelMembership, ServerConnection}
  alias Ircpipe.Irc.Identifier
  alias Ircpipe.Repo

  def get!(%User{id: user_id}, id) do
    ChannelMembership
    |> where([membership], membership.user_id == ^user_id and membership.id == ^id)
    |> preload(:server_connection)
    |> Repo.one!()
  end

  def find_by_channel(
        %ServerConnection{} = connection,
        channel,
        casemapping \\ :rfc1459,
        status \\ nil
      ) do
    query =
      from(membership in ChannelMembership,
        where: membership.server_connection_id == ^connection.id
      )

    query =
      if status,
        do: where(query, [membership], membership.status == ^status),
        else: query

    key = Identifier.key(channel, casemapping)

    query
    |> Repo.all()
    |> Enum.find(&(Identifier.key(&1.channel, casemapping) == key))
  end

  def get_by_channel!(
        %User{id: user_id},
        %ServerConnection{} = connection,
        channel,
        casemapping \\ nil
      ) do
    mapping = casemapping || casemapping(connection) || :ascii

    case find_by_channel(connection, channel, mapping) do
      %ChannelMembership{user_id: ^user_id} = membership ->
        Repo.preload(membership, :server_connection)

      _membership ->
        raise Ecto.NoResultsError, queryable: ChannelMembership
    end
  end

  def casemapping(%ServerConnection{casemapping: mapping}) when is_binary(mapping) do
    case mapping do
      "ascii" -> :ascii
      "strict_rfc1459" -> :strict_rfc1459
      _mapping -> :rfc1459
    end
  end

  def casemapping(%ServerConnection{}), do: nil
end
