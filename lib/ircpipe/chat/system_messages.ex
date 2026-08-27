defmodule Ircpipe.Chat.SystemMessages do
  @moduledoc false

  import Ecto.Query

  alias Ircpipe.Accounts.User

  alias Ircpipe.Chat.{
    BufferEvents,
    ChannelMembership,
    Message,
    Presence,
    Retention,
    ServerConnection
  }

  alias Ircpipe.Irc.Identifier
  alias Ircpipe.Repo

  def record(
        %ServerConnection{} = connection,
        channel,
        kind,
        nick,
        body,
        metadata \\ %{},
        casemapping \\ :rfc1459
      ) do
    assert_no_outer_transaction!()

    membership =
      channel_membership(connection, channel, casemapping) ||
        raise(Ecto.NoResultsError, queryable: ChannelMembership)

    user = Repo.get!(User, connection.user_id)

    Repo.transaction(fn ->
      {:ok, message} =
        %Message{
          user_id: connection.user_id,
          server_connection_id: connection.id,
          channel_membership_id: membership.id
        }
        |> Message.changeset(%{
          kind: kind,
          nick: nick,
          metadata: stringify_metadata(metadata),
          body: body,
          mentioned: false,
          occurred_at: DateTime.utc_now(:second)
        })
        |> Repo.insert()

      Retention.prune(user)
      message
    end)
    |> case do
      {:ok, message} ->
        BufferEvents.message(message, membership, connection)
        {:ok, message}

      error ->
        error
    end
  end

  def record_for_present_nick(%ServerConnection{} = connection, kind, nick, body_fun)
      when is_binary(nick) and is_function(body_fun, 1) do
    record_for_present_nick(connection, kind, nick, nick, body_fun)
  end

  def record_for_present_nick(
        %ServerConnection{} = connection,
        kind,
        present_nick,
        message_nick,
        body_fun
      )
      when is_binary(present_nick) and is_function(body_fun, 1) do
    assert_no_outer_transaction!()

    connection
    |> Presence.memberships_with_nick(present_nick)
    |> Enum.each(fn membership ->
      record(
        connection,
        membership.channel,
        kind,
        message_nick,
        body_fun.(membership)
      )
    end)
  end

  defp stringify_metadata(metadata) when is_map(metadata) do
    Map.new(metadata, fn {key, value} -> {to_string(key), value} end)
  end

  defp stringify_metadata(_metadata), do: %{}

  defp assert_no_outer_transaction! do
    if Repo.in_transaction?() do
      raise ArgumentError, "cannot persist system messages inside an existing transaction"
    end
  end

  defp channel_membership(connection, channel, casemapping) do
    key = Identifier.key(channel, casemapping)

    ChannelMembership
    |> where([membership], membership.server_connection_id == ^connection.id)
    |> Repo.all()
    |> Enum.find(&(Identifier.key(&1.channel, casemapping) == key))
  end
end
