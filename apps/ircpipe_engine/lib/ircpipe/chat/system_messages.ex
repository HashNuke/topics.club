defmodule Ircpipe.Chat.SystemMessages do
  @moduledoc false

  alias Ircpipe.Accounts.User

  alias Ircpipe.Chat.{
    BufferEvents,
    ChannelMembership,
    Message,
    PresenceMembershipLookup,
    Retention,
    ServerConnection,
    ServerConnectionLock
  }

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
      PresenceMembershipLookup.find(connection, channel, casemapping) ||
        raise(Ecto.NoResultsError, queryable: ChannelMembership)

    user = Repo.get!(User, connection.user_id)

    Repo.transaction(fn ->
      active_connection = ServerConnectionLock.lock_active!(connection.id)

      {:ok, message} =
        %Message{
          user_id: active_connection.user_id,
          server_connection_id: active_connection.id,
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
      {message, active_connection}
    end)
    |> case do
      {:ok, {message, active_connection}} ->
        _effects =
          ServerConnectionLock.serialize_effects(active_connection.id, fn effect_connection ->
            BufferEvents.message(message, membership, effect_connection)
          end)

        {:ok, message}

      error ->
        error
    end
  end

  def record_for_present_nick(%ServerConnection{} = connection, kind, nick, body_fun, casemapping)
      when is_binary(nick) and is_function(body_fun, 1) do
    record_for_present_nick(connection, kind, nick, nick, body_fun, casemapping)
  end

  def record_for_present_nick(
        %ServerConnection{} = connection,
        kind,
        present_nick,
        message_nick,
        body_fun,
        casemapping
      )
      when is_binary(present_nick) and is_function(body_fun, 1) do
    assert_no_outer_transaction!()

    connection
    |> PresenceMembershipLookup.with_nick(present_nick, casemapping)
    |> Enum.each(fn membership ->
      record(
        connection,
        membership.channel,
        kind,
        message_nick,
        body_fun.(membership),
        %{},
        casemapping
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
end
