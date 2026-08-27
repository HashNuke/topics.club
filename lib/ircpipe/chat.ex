defmodule Ircpipe.Chat do
  import Ecto.Query

  alias Ircpipe.Accounts.User

  alias Ircpipe.Chat.{
    BufferEvents,
    ChannelMembership,
    ChannelUser,
    MembershipReconciler,
    Message,
    Presence,
    Retention,
    ServerConnection
  }

  alias Ircpipe.Irc.Identifier
  alias Ircpipe.Repo

  def update_connection_casemapping(%ServerConnection{} = connection, casemapping) do
    mapping = Atom.to_string(casemapping)

    connection
    |> Ecto.Changeset.change(casemapping: mapping)
    |> Repo.update()
  end

  def request_channel_join(user, %ServerConnection{} = connection, channel),
    do: request_channel_join(user, connection, channel, stored_casemapping(connection) || :ascii)

  def request_channel_join(
        %User{id: user_id} = user,
        %ServerConnection{user_id: user_id} = connection,
        channel,
        casemapping
      ) do
    channel = String.trim(channel)

    case Repo.transaction(fn ->
           losers = MembershipReconciler.reconcile_in_transaction(connection, casemapping)

           membership =
             case channel_membership(connection, channel, casemapping) do
               %ChannelMembership{} = membership ->
                 attrs =
                   if membership.status == "joined" do
                     %{auto_join: true, left_at: nil, last_error: nil}
                   else
                     %{status: "pending", auto_join: true, left_at: nil, last_error: nil}
                   end

                 membership
                 |> ChannelMembership.changeset(attrs)
                 |> Repo.update!()

               nil ->
                 %ChannelMembership{user_id: user.id, server_connection_id: connection.id}
                 |> ChannelMembership.changeset(%{
                   channel: channel,
                   status: "pending",
                   auto_join: true
                 })
                 |> Repo.insert!()
             end

           {membership, losers}
         end) do
      {:ok, {membership, losers}} ->
        MembershipReconciler.broadcast_losers(connection, losers)
        {:ok, membership}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def request_channel_join(%User{}, %ServerConnection{}, _channel, _casemapping),
    do: {:error, :invalid_connection}

  def join_channel(%User{} = user, %ServerConnection{} = connection, channel) do
    with {:ok, pending} <- request_channel_join(user, connection, channel),
         {:ok, membership} <- confirm_channel_join(connection, pending.channel) do
      {:ok, membership}
    end
  end

  def confirm_channel_join(
        %ServerConnection{} = connection,
        channel,
        casemapping \\ :rfc1459,
        connection_status \\ nil
      ) do
    now = DateTime.utc_now(:second)

    {result, broadcast?} =
      case channel_membership(connection, channel, casemapping) do
        %ChannelMembership{} = membership ->
          result =
            membership
            |> ChannelMembership.changeset(%{
              status: "joined",
              auto_join: membership.auto_join,
              joined_at: if(membership.status == "joined", do: membership.joined_at, else: now),
              left_at: nil,
              last_error: nil
            })
            |> Repo.update()

          {result, membership.status != "joined"}

        nil ->
          result =
            %ChannelMembership{user_id: connection.user_id, server_connection_id: connection.id}
            |> ChannelMembership.changeset(%{
              channel: channel,
              status: "joined",
              auto_join: false,
              joined_at: now
            })
            |> Repo.insert()

          {result, true}
      end

    with {:ok, membership} <- result do
      if broadcast?, do: BufferEvents.joined(connection, membership, connection_status)
      {:ok, membership}
    end
  end

  def reject_channel_join(
        %ServerConnection{} = connection,
        channel,
        reason,
        casemapping \\ :rfc1459
      ) do
    case channel_membership(connection, channel, casemapping) do
      %ChannelMembership{} = membership ->
        result =
          membership
          |> ChannelMembership.changeset(%{
            status: "error",
            auto_join: false,
            last_error: reason_text(reason)
          })
          |> Repo.update()

        with {:ok, rejected} <- result do
          BufferEvents.left(%{
            user_id: connection.user_id,
            buffer_id: "channel:#{rejected.id}",
            server_connection_id: connection.id,
            channel_membership_id: rejected.id,
            channel: rejected.channel
          })

          {:ok, rejected}
        end

      nil ->
        {:error, :invalid_buffer}
    end
  end

  def confirm_channel_left(%ServerConnection{} = connection, channel, casemapping \\ :rfc1459) do
    case channel_membership(connection, channel, casemapping) do
      %ChannelMembership{} = membership ->
        result =
          membership
          |> ChannelMembership.changeset(%{
            status: "left",
            auto_join: false,
            left_at:
              if(membership.status == "left",
                do: membership.left_at,
                else: DateTime.utc_now(:second)
              ),
            last_error: nil
          })
          |> Repo.update()

        with {:ok, updated} <- result do
          from(u in ChannelUser, where: u.channel_membership_id == ^updated.id)
          |> Repo.delete_all()

          if membership.status != "left" do
            BufferEvents.left(%{
              user_id: connection.user_id,
              buffer_id: "channel:#{updated.id}",
              server_connection_id: connection.id,
              channel_membership_id: updated.id
            })
          end

          {:ok, updated}
        end

      nil ->
        {:error, :invalid_buffer}
    end
  end

  def reject_channel_part(
        %ServerConnection{} = connection,
        channel,
        reason,
        casemapping \\ :rfc1459
      ) do
    case channel_membership(connection, channel, casemapping, "joined") do
      %ChannelMembership{} = membership ->
        membership
        |> ChannelMembership.changeset(%{last_error: reason_text(reason)})
        |> Repo.update()

      nil ->
        {:error, :invalid_buffer}
    end
  end

  def get_membership!(%User{id: user_id}, id) do
    ChannelMembership
    |> where([m], m.user_id == ^user_id and m.id == ^id)
    |> preload(:server_connection)
    |> Repo.one!()
  end

  def get_channel_membership(%ServerConnection{} = connection, channel, casemapping \\ :rfc1459),
    do: channel_membership(connection, channel, casemapping)

  def get_membership_by_channel!(
        %User{id: user_id},
        %ServerConnection{} = connection,
        channel,
        casemapping \\ nil
      ) do
    mapping = casemapping || stored_casemapping(connection) || :ascii

    case channel_membership(connection, channel, mapping) do
      %ChannelMembership{user_id: ^user_id} = membership ->
        Repo.preload(membership, :server_connection)

      _membership ->
        raise Ecto.NoResultsError, queryable: ChannelMembership
    end
  end

  def record_channel_system_message(
        %ServerConnection{} = connection,
        channel,
        kind,
        nick,
        body,
        metadata \\ %{},
        casemapping \\ :rfc1459
      ) do
    membership =
      case channel_membership(connection, channel, casemapping) do
        %ChannelMembership{} = membership -> membership
        nil -> raise Ecto.NoResultsError, queryable: ChannelMembership
      end

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

  def record_command_message(
        %ServerConnection{} = connection,
        buffer_id,
        body,
        metadata
      ) do
    membership = command_membership(connection, buffer_id)
    user = Repo.get!(User, connection.user_id)

    Repo.transaction(fn ->
      {:ok, message} =
        %Message{
          user_id: connection.user_id,
          server_connection_id: connection.id,
          channel_membership_id: membership && membership.id
        }
        |> Message.changeset(%{
          kind: "command",
          nick: connection.nickname,
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
        BufferEvents.command_message(message, membership, connection)
        {:ok, message}

      error ->
        error
    end
  end

  def update_command_message(%Message{} = message, metadata) when is_map(metadata) do
    merged_metadata = Map.merge(message.metadata || %{}, stringify_metadata(metadata))

    Repo.transaction(fn ->
      {:ok, message} =
        message
        |> Message.changeset(%{metadata: merged_metadata})
        |> Repo.update()

      connection = Repo.get!(ServerConnection, message.server_connection_id)
      membership = membership_for_message(message)
      {message, membership, connection}
    end)
    |> case do
      {:ok, {message, membership, connection}} ->
        BufferEvents.command_message(message, membership, connection)
        {:ok, message}

      error ->
        error
    end
  end

  def record_channel_system_message_all(%ServerConnection{} = connection, kind, nick, body_fun)
      when is_function(body_fun, 1) do
    connection
    |> Presence.memberships(nil)
    |> Enum.each(fn membership ->
      record_channel_system_message(
        connection,
        membership.channel,
        kind,
        nick,
        body_fun.(membership)
      )
    end)
  end

  def record_channel_system_message_for_present_nick(
        %ServerConnection{} = connection,
        kind,
        nick,
        body_fun
      )
      when is_binary(nick) and is_function(body_fun, 1) do
    record_channel_system_message_for_present_nick(connection, kind, nick, nick, body_fun)
  end

  def record_channel_system_message_for_present_nick(
        %ServerConnection{} = connection,
        kind,
        present_nick,
        message_nick,
        body_fun
      )
      when is_binary(present_nick) and is_function(body_fun, 1) do
    connection
    |> Presence.memberships_with_nick(present_nick)
    |> Enum.each(fn membership ->
      record_channel_system_message(
        connection,
        membership.channel,
        kind,
        message_nick,
        body_fun.(membership)
      )
    end)
  end

  def leave_channel(%User{id: user_id}, %ChannelMembership{} = membership) do
    if membership.user_id == user_id do
      connection = Repo.get!(ServerConnection, membership.server_connection_id)

      case confirm_channel_left(connection, membership.channel) do
        {:ok, _membership} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :invalid_buffer}
    end
  end

  defp stringify_metadata(metadata) when is_map(metadata) do
    Map.new(metadata, fn {key, value} -> {to_string(key), value} end)
  end

  defp stringify_metadata(_metadata), do: %{}

  defp reason_text(reason) when is_binary(reason), do: reason
  defp reason_text(reason), do: inspect(reason)

  defp command_membership(%ServerConnection{id: connection_id}, "channel:" <> membership_id) do
    Repo.get_by!(ChannelMembership, id: membership_id, server_connection_id: connection_id)
  end

  defp command_membership(%ServerConnection{id: connection_id}, "server:" <> connection_id_text)
       when is_binary(connection_id_text) do
    if Integer.to_string(connection_id) == connection_id_text,
      do: nil,
      else: raise(Ecto.NoResultsError, queryable: ServerConnection)
  end

  defp command_membership(%ServerConnection{}, _buffer_id),
    do: raise(Ecto.NoResultsError, queryable: ChannelMembership)

  defp membership_for_message(%Message{channel_membership_id: nil}), do: nil

  defp membership_for_message(%Message{channel_membership_id: membership_id}),
    do: Repo.get!(ChannelMembership, membership_id)

  defp channel_membership(connection, channel, casemapping, status \\ nil) do
    query =
      from(m in ChannelMembership,
        where: m.server_connection_id == ^connection.id
      )

    query = if status, do: where(query, [m], m.status == ^status), else: query
    key = Identifier.key(channel, casemapping)

    query
    |> Repo.all()
    |> Enum.find(&(Identifier.key(&1.channel, casemapping) == key))
  end

  defp stored_casemapping(%ServerConnection{casemapping: mapping}) when is_binary(mapping) do
    case mapping do
      "ascii" -> :ascii
      "strict_rfc1459" -> :strict_rfc1459
      _mapping -> :rfc1459
    end
  end

  defp stored_casemapping(%ServerConnection{}), do: nil
end
