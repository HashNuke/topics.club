defmodule Ircpipe.Chat do
  import Ecto.Query

  alias Ircpipe.Accounts.User

  alias Ircpipe.Chat.{
    ChannelMembership,
    ChannelUser,
    Message,
    Notification,
    ServerConnection,
    Topic
  }

  alias Ircpipe.Realtime.Event
  alias Ircpipe.Repo
  alias Ircxd.Casemapping

  def list_topics do
    Topic
    |> order_by([t], asc: t.sort_order, asc: t.name)
    |> Repo.all()
  end

  def get_topic!(id), do: Repo.get!(Topic, id)

  def list_connections(%User{id: user_id}) do
    connections =
      ServerConnection
      |> where([c], c.user_id == ^user_id)
      |> order_by([c], asc: c.name)
      |> Repo.all()

    Enum.each(connections, fn connection ->
      if mapping = stored_casemapping(connection) do
        reconcile_channel_memberships(connection, mapping)
      end
    end)

    Repo.preload(connections, :channel_memberships, force: true)
  end

  def list_recently_seen_connections(cutoff) do
    ServerConnection
    |> join(:inner, [c], u in User, on: u.id == c.user_id)
    |> where([_c, u], not is_nil(u.last_seen_at) and u.last_seen_at >= ^cutoff)
    |> preload(:channel_memberships)
    |> order_by([c], asc: c.user_id, asc: c.name)
    |> Repo.all()
  end

  def list_inactive_connections(cutoff) do
    ServerConnection
    |> join(:inner, [c], u in User, on: u.id == c.user_id)
    |> where([c, u], c.status != "disconnected")
    |> where([_c, u], is_nil(u.last_seen_at) or u.last_seen_at < ^cutoff)
    |> preload(:channel_memberships)
    |> order_by([c], asc: c.user_id, asc: c.name)
    |> Repo.all()
  end

  def get_connection!(%User{id: user_id}, id) do
    ServerConnection
    |> where([c], c.user_id == ^user_id and c.id == ^id)
    |> preload(:channel_memberships)
    |> Repo.one!()
  end

  def create_connection(%User{} = user, attrs) do
    attrs = connection_defaults(user, attrs)

    %ServerConnection{user_id: user.id}
    |> ServerConnection.changeset(attrs)
    |> Repo.insert()
  end

  def create_or_get_connection(%User{} = user, attrs) do
    name = Map.get(attrs, "name") || Map.get(attrs, :name)

    case name && Repo.get_by(ServerConnection, user_id: user.id, name: name) do
      %ServerConnection{} = connection -> {:ok, connection}
      _ -> create_connection(user, attrs)
    end
  end

  def update_connection(%User{} = user, id, attrs) do
    user
    |> get_connection!(id)
    |> ServerConnection.changeset(attrs)
    |> Repo.update()
  end

  def delete_connection(%User{} = user, id) do
    connection = get_connection!(user, id)

    {:ok, disconnected} = update_connection_status(connection, "disconnected")

    Enum.each(connection.channel_memberships, fn membership ->
      broadcast_buffer_left(%{
        user_id: user.id,
        buffer_id: "channel:#{membership.id}",
        server_connection_id: connection.id,
        channel_membership_id: membership.id
      })
    end)

    broadcast_buffer_left(%{
      user_id: user.id,
      buffer_id: "server:#{connection.id}",
      server_connection_id: connection.id,
      channel_membership_id: nil
    })

    Repo.delete(disconnected)
  end

  def join_topic(%User{} = user, %Topic{} = topic) do
    Repo.transaction(fn ->
      {:ok, connection} =
        create_or_get_connection(user, %{
          "name" => topic.server_host,
          "host" => topic.server_host,
          "port" => topic.server_port,
          "use_tls" => topic.use_tls,
          "nickname" => default_nick(user)
        })

      connection = ensure_valid_nick(connection, user)
      %{connection: connection, topic: topic}
    end)
  end

  def update_connection_status(%ServerConnection{} = connection, status) do
    connection
    |> ServerConnection.changeset(%{
      status: status,
      last_connected_at: if(status == "connected", do: DateTime.utc_now(:second))
    })
    |> Repo.update()
    |> tap(fn
      {:ok, updated} -> broadcast_server_status(updated)
      _other -> :ok
    end)
  end

  def update_connection_nickname(%ServerConnection{} = connection, nickname) do
    connection
    |> ServerConnection.changeset(%{nickname: nickname})
    |> Repo.update()
    |> tap(fn
      {:ok, updated} -> broadcast_server_status(updated)
      _other -> :ok
    end)
  end

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
           lock_memberships(connection)
           losers = reconcile_channel_memberships_locked(connection, casemapping)

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
        Enum.each(losers, &broadcast_reconciled_membership(&1, connection))
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

  def confirm_channel_join(%ServerConnection{} = connection, channel, casemapping \\ :rfc1459) do
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
      if broadcast?, do: broadcast_buffer_joined(connection, membership)
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
          broadcast_buffer_left(%{
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
            broadcast_buffer_left(%{
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

  def list_messages(%User{id: user_id}, membership_id, limit \\ 200) do
    Message
    |> where([m], m.user_id == ^user_id and m.channel_membership_id == ^membership_id)
    |> order_by([m], desc: m.occurred_at, desc: m.id)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.reverse()
  end

  def list_channel_users(%ChannelMembership{} = membership) do
    ChannelUser
    |> where([u], u.channel_membership_id == ^membership.id)
    |> order_by([u], asc: u.nick)
    |> Repo.all()
    |> Enum.map(&channel_user_json/1)
  end

  def list_buffer_messages(user, buffer_id, opts \\ [])

  def list_buffer_messages(%User{} = user, "channel:" <> membership_id, opts) do
    membership = get_membership!(user, membership_id)
    limit = opts |> Keyword.get(:limit, 150) |> to_int(150) |> min(150) |> max(1)

    query =
      Message
      |> where([m], m.user_id == ^user.id and m.channel_membership_id == ^membership.id)
      |> cursor_filter(user, opts)

    list_cursor_messages(query, opts, limit)
  end

  def list_buffer_messages(%User{} = user, "server:" <> connection_id, opts) do
    connection = get_connection!(user, connection_id)
    limit = opts |> Keyword.get(:limit, 150) |> to_int(150) |> min(150) |> max(1)

    query =
      Message
      |> where(
        [m],
        m.user_id == ^user.id and m.server_connection_id == ^connection.id and
          is_nil(m.channel_membership_id)
      )
      |> cursor_filter(user, opts)

    list_cursor_messages(query, opts, limit)
  end

  def list_buffer_messages(%User{}, _buffer_id, _opts), do: []

  def list_buffer_command_messages(%User{} = user, buffer_id, command_ids)
      when is_list(command_ids) do
    ids = command_ids |> Enum.filter(&is_binary/1) |> Enum.uniq() |> Enum.take(50)

    query =
      case buffer_id do
        "channel:" <> membership_id ->
          membership = get_membership!(user, membership_id)

          from(message in Message,
            where:
              message.user_id == ^user.id and
                message.channel_membership_id == ^membership.id
          )

        "server:" <> connection_id ->
          connection = get_connection!(user, connection_id)

          from(message in Message,
            where:
              message.user_id == ^user.id and
                message.server_connection_id == ^connection.id and
                is_nil(message.channel_membership_id)
          )

        _invalid_buffer ->
          from(message in Message, where: false)
      end

    query
    |> where(
      [message],
      message.kind == "command" and
        fragment("?->>'command_id'", message.metadata) in ^ids and
        fragment("?->>'command_status'", message.metadata) != "result"
    )
    |> order_by([message], asc: message.occurred_at, asc: message.id)
    |> limit(50)
    |> Repo.all()
  end

  def record_inbound_message(
        %ServerConnection{} = connection,
        channel,
        nick,
        body,
        kind \\ "message",
        metadata \\ %{},
        casemapping \\ :rfc1459
      ) do
    membership =
      channel_membership(connection, channel, casemapping, "joined") ||
        raise(Ecto.NoResultsError, queryable: ChannelMembership)

    user = Repo.get!(User, connection.user_id)
    mentioned = mention?(body, connection.nickname)

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
          hostmask: metadata_value(metadata, :hostmask),
          sender_role: metadata_value(metadata, :sender_role),
          service: metadata_value(metadata, :service),
          metadata: stringify_metadata(metadata),
          body: body,
          mentioned: mentioned,
          occurred_at: DateTime.utc_now(:second)
        })
        |> Repo.insert()

      counters = [inc: [unread_count: 1]]

      counters =
        if mentioned,
          do: Keyword.update!(counters, :inc, &([mention_count: 1] ++ &1)),
          else: counters

      {1, _} =
        Repo.update_all(from(m in ChannelMembership, where: m.id == ^membership.id), counters)

      notification =
        if mentioned do
          {:ok, notification} =
            %Notification{
              user_id: connection.user_id,
              message_id: message.id,
              channel_membership_id: membership.id
            }
            |> Notification.changeset(%{})
            |> Repo.insert()

          notification
        end

      prune_old_messages(user)
      broadcast_message(message, membership, connection, notification)
      %{message | channel_membership: membership, server_connection: connection}
    end)
  end

  def record_server_message(
        %ServerConnection{} = connection,
        body,
        kind \\ "system",
        nick \\ nil,
        metadata \\ %{}
      ) do
    user = Repo.get!(User, connection.user_id)

    Repo.transaction(fn ->
      {:ok, message} =
        %Message{
          user_id: connection.user_id,
          server_connection_id: connection.id
        }
        |> Message.changeset(%{
          kind: kind,
          nick: nick || connection.host,
          service: metadata_value(metadata, :service),
          metadata: stringify_metadata(metadata),
          body: body,
          mentioned: false,
          occurred_at: DateTime.utc_now(:second)
        })
        |> Repo.insert()

      {1, _} =
        Repo.update_all(
          from(c in ServerConnection, where: c.id == ^connection.id),
          inc: [unread_count: 1]
        )

      prune_old_messages(user)
      broadcast_server_message(message, connection)
      message
    end)
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
    membership = channel_membership(connection, channel, casemapping)

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

      prune_old_messages(user)
      broadcast_message(message, membership, connection, nil)
      message
    end)
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

      prune_old_messages(user)
      broadcast_command_message(message, membership, connection)
      message
    end)
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
      broadcast_command_message(message, membership, connection)
      message
    end)
  end

  def record_channel_system_message_all(%ServerConnection{} = connection, kind, nick, body_fun)
      when is_function(body_fun, 1) do
    connection
    |> presence_memberships(nil)
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
    |> presence_memberships_with_nick(present_nick)
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

  def mark_read(%User{id: user_id}, %ChannelMembership{} = membership) do
    now = DateTime.utc_now(:second)

    from(m in ChannelMembership, where: m.id == ^membership.id and m.user_id == ^user_id)
    |> Repo.update_all(set: [last_read_at: now, unread_count: 0, mention_count: 0])

    from(n in Notification,
      where:
        n.user_id == ^user_id and n.channel_membership_id == ^membership.id and is_nil(n.read_at)
    )
    |> Repo.update_all(set: [read_at: now])

    broadcast_buffer_read(%{
      user_id: user_id,
      buffer_id: "channel:#{membership.id}",
      server_connection_id: membership.server_connection_id,
      channel_membership_id: membership.id
    })

    :ok
  end

  def mark_read(%User{id: user_id}, %ServerConnection{} = connection) do
    now = DateTime.utc_now(:second)

    from(c in ServerConnection, where: c.id == ^connection.id and c.user_id == ^user_id)
    |> Repo.update_all(set: [last_read_at: now, unread_count: 0, mention_count: 0])

    broadcast_buffer_read(%{
      user_id: user_id,
      buffer_id: "server:#{connection.id}",
      server_connection_id: connection.id,
      channel_membership_id: nil
    })

    :ok
  end

  def broadcast_presence_sync(
        %ServerConnection{} = connection,
        channel,
        names,
        casemapping \\ :rfc1459
      ) do
    case channel_membership(connection, channel, casemapping) do
      %ChannelMembership{} = membership ->
        users = Enum.map(names, &presence_user/1)
        sync_channel_users(membership, users)

        event =
          Event.presence_sync(%{
            buffer_id: "channel:#{membership.id}",
            server_connection_id: connection.id,
            channel_membership_id: membership.id,
            users: users
          })

        Phoenix.PubSub.broadcast(
          Ircpipe.PubSub,
          "user:#{connection.user_id}",
          {:presence_sync, event}
        )

      nil ->
        :ok
    end
  end

  def broadcast_presence_diff(
        %ServerConnection{} = connection,
        channel,
        diff,
        casemapping \\ :rfc1459
      ) do
    connection
    |> presence_memberships(channel, casemapping)
    |> Enum.each(fn membership ->
      apply_presence_diff(membership, diff)

      event =
        Event.presence_diff(%{
          buffer_id: "channel:#{membership.id}",
          server_connection_id: connection.id,
          channel_membership_id: membership.id,
          diff: diff
        })

      Phoenix.PubSub.broadcast(
        Ircpipe.PubSub,
        "user:#{connection.user_id}",
        {:presence_diff, event}
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

  def broadcast_buffer_left(payload) do
    user_id = Map.fetch!(payload, :user_id)

    event =
      payload
      |> Event.buffer_left()
      |> Map.drop([:user_id])

    Phoenix.PubSub.broadcast(
      Ircpipe.PubSub,
      "user:#{user_id}",
      {:buffer_left, event}
    )
  end

  def broadcast_buffer_read(payload) do
    user_id = Map.fetch!(payload, :user_id)

    event =
      payload
      |> Event.buffer_read()
      |> Map.drop([:user_id])

    Phoenix.PubSub.broadcast(
      Ircpipe.PubSub,
      "user:#{user_id}",
      {:buffer_read, event}
    )
  end

  def broadcast_buffer_joined(%ServerConnection{} = connection, %ChannelMembership{} = membership) do
    Phoenix.PubSub.broadcast(
      Ircpipe.PubSub,
      "user:#{connection.user_id}",
      {:buffer_joined, Event.buffer_joined(connection, membership)}
    )
  end

  def update_retention_days(%User{} = user, days) do
    days =
      days
      |> to_int(3)
      |> min(3)
      |> max(1)

    user
    |> Ecto.Changeset.change(message_retention_days: days)
    |> Repo.update()
  end

  def prune_old_messages(%User{} = user) do
    cutoff = DateTime.add(DateTime.utc_now(:second), -user.message_retention_days, :day)

    from(m in Message, where: m.user_id == ^user.id and m.occurred_at < ^cutoff)
    |> Repo.delete_all()
  end

  def normalize_channel(<<prefix, _rest::binary>> = channel) when prefix in [?#, ?&, ?+, ?!],
    do: channel

  def normalize_channel(channel), do: "##{channel}"

  def channel_key(channel, casemapping \\ :rfc1459) do
    Casemapping.normalize(channel, casemapping)
  end

  def valid_nick?(nick) when is_binary(nick) do
    String.match?(nick, ~r/^[A-Za-z_\[\]\\`^{}][A-Za-z0-9_\-\[\]\\`^{}]{0,23}$/)
  end

  def valid_nick?(_nick), do: false

  defp default_nick(%User{email: email}) do
    base =
      email
      |> String.split("@")
      |> List.first()
      |> String.replace(~r/[^A-Za-z0-9_\-\[\]\\`^{}]/, "_")
      |> String.trim("_-")

    base =
      cond do
        base == "" -> "topics_user"
        String.match?(String.first(base), ~r/^[A-Za-z_\[\]\\`^{}]$/) -> base
        true -> "u_#{base}"
      end

    String.slice(base, 0, 24)
  end

  defp connection_defaults(user, attrs) do
    nickname = present_attr(attrs, :nickname) || default_nick(user)

    attrs
    |> put_attr(:nickname, nickname)
    |> maybe_put_sasl_username(nickname)
  end

  defp maybe_put_sasl_username(attrs, nickname) do
    if present_attr(attrs, :sasl_password) && !present_attr(attrs, :sasl_username) do
      put_attr(attrs, :sasl_username, nickname)
    else
      attrs
    end
  end

  defp present_attr(attrs, key) do
    value = Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
    if is_binary(value) && String.trim(value) != "", do: String.trim(value)
  end

  defp put_attr(attrs, key, value) do
    cond do
      Map.has_key?(attrs, key) -> Map.put(attrs, key, value)
      Map.has_key?(attrs, Atom.to_string(key)) -> Map.put(attrs, Atom.to_string(key), value)
      Enum.any?(Map.keys(attrs), &is_atom/1) -> Map.put(attrs, key, value)
      true -> Map.put(attrs, Atom.to_string(key), value)
    end
  end

  defp ensure_valid_nick(%ServerConnection{} = connection, %User{} = user) do
    if valid_nick?(connection.nickname) do
      connection
    else
      {:ok, connection} =
        connection
        |> ServerConnection.changeset(%{nickname: default_nick(user), status: "disconnected"})
        |> Repo.update()

      connection
    end
  end

  defp before_cursor(query, %User{id: user_id}, before_id) when is_binary(before_id) do
    case Integer.parse(before_id) do
      {id, ""} ->
        before_cursor(query, %User{id: user_id}, id)

      _ ->
        query
    end
  end

  defp before_cursor(query, %User{id: user_id}, before_id) when is_integer(before_id) do
    case Repo.get_by(Message, id: before_id, user_id: user_id) do
      %Message{} = cursor ->
        where(
          query,
          [m],
          m.occurred_at < ^cursor.occurred_at or
            (m.occurred_at == ^cursor.occurred_at and m.id < ^cursor.id)
        )

      nil ->
        query
    end
  end

  defp before_cursor(query, _user, _before_id), do: query

  defp after_cursor(query, %User{id: user_id}, after_id) when is_binary(after_id) do
    case Integer.parse(after_id) do
      {id, ""} ->
        after_cursor(query, %User{id: user_id}, id)

      _ ->
        query
    end
  end

  defp after_cursor(query, %User{id: user_id}, after_id) when is_integer(after_id) do
    case Repo.get_by(Message, id: after_id, user_id: user_id) do
      %Message{} = cursor ->
        where(
          query,
          [m],
          m.occurred_at > ^cursor.occurred_at or
            (m.occurred_at == ^cursor.occurred_at and m.id > ^cursor.id)
        )

      nil ->
        query
    end
  end

  defp after_cursor(query, _user, _after_id), do: query

  defp cursor_filter(query, user, opts) do
    cond do
      opts[:after] -> after_cursor(query, user, opts[:after])
      opts[:before] -> before_cursor(query, user, opts[:before])
      true -> query
    end
  end

  defp list_cursor_messages(query, opts, limit) do
    if opts[:after] do
      query
      |> order_by([m], asc: m.occurred_at, asc: m.id)
      |> limit(^limit)
      |> Repo.all()
    else
      query
      |> order_by([m], desc: m.occurred_at, desc: m.id)
      |> limit(^limit)
      |> Repo.all()
      |> Enum.reverse()
    end
  end

  defp mention?(body, nickname) when is_binary(body) and is_binary(nickname) do
    body
    |> String.downcase()
    |> String.contains?(String.downcase(nickname))
  end

  defp mention?(_, _), do: false

  defp metadata_value(metadata, key) do
    Map.get(metadata, key) || Map.get(metadata, Atom.to_string(key))
  end

  defp stringify_metadata(metadata) when is_map(metadata) do
    Map.new(metadata, fn {key, value} -> {to_string(key), value} end)
  end

  defp stringify_metadata(_metadata), do: %{}

  defp reason_text(reason) when is_binary(reason), do: reason
  defp reason_text(reason), do: inspect(reason)

  defp broadcast_message(message, membership, connection, notification) do
    payload = Event.message(message, "channel:#{membership.id}", %{channel: membership.channel})

    Phoenix.PubSub.broadcast(
      Ircpipe.PubSub,
      "user:#{connection.user_id}",
      {:irc_message, payload}
    )

    Phoenix.PubSub.broadcast(
      Ircpipe.PubSub,
      "user:#{connection.user_id}",
      {pubsub_event(payload), payload}
    )

    if notification do
      Phoenix.PubSub.broadcast(
        Ircpipe.PubSub,
        "user:#{connection.user_id}",
        {:irc_mention, Event.notification_mention(payload)}
      )
    end
  end

  defp broadcast_server_message(message, connection) do
    event = Event.message(message, "server:#{connection.id}", %{mentioned: false})

    Phoenix.PubSub.broadcast(
      Ircpipe.PubSub,
      "user:#{connection.user_id}",
      {pubsub_event(event), event}
    )
  end

  defp broadcast_command_message(message, nil, connection),
    do: broadcast_server_message(message, connection)

  defp broadcast_command_message(message, membership, connection),
    do: broadcast_message(message, membership, connection, nil)

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

  defp broadcast_server_status(connection) do
    Phoenix.PubSub.broadcast(
      Ircpipe.PubSub,
      "user:#{connection.user_id}",
      {:server_status, Event.server_status(connection)}
    )
  end

  defp presence_user(name) do
    %{
      nick: name.nick,
      role: role_for_prefixes(Map.get(name, :prefixes, [])),
      status: "online",
      hostmask: Map.get(name, :raw_source),
      last_observed_at: DateTime.utc_now(:second)
    }
  end

  defp channel_user_json(%ChannelUser{} = user) do
    %{
      nick: user.nick,
      role: user.role,
      status: user.status,
      hostmask: user.hostmask,
      last_observed_at: user.last_observed_at
    }
  end

  defp sync_channel_users(%ChannelMembership{} = membership, users) do
    now = DateTime.utc_now(:second)

    Repo.transaction(fn ->
      from(u in ChannelUser, where: u.channel_membership_id == ^membership.id)
      |> Repo.delete_all()

      entries =
        Enum.map(users, fn user ->
          user
          |> channel_user_attrs(now)
          |> Map.merge(%{
            channel_membership_id: membership.id,
            inserted_at: now,
            updated_at: now
          })
        end)

      if entries != [] do
        Repo.insert_all(ChannelUser, entries)
      end
    end)
  end

  defp apply_presence_diff(%ChannelMembership{} = membership, %{action: "join", user: user}) do
    upsert_channel_user(membership, user)
  end

  defp apply_presence_diff(%ChannelMembership{} = membership, %{action: action, nick: nick})
       when action in ["part", "quit"] and is_binary(nick) do
    from(u in ChannelUser, where: u.channel_membership_id == ^membership.id and u.nick == ^nick)
    |> Repo.delete_all()
  end

  defp apply_presence_diff(%ChannelMembership{} = membership, %{
         action: "nick",
         old_nick: old_nick,
         new_nick: new_nick
       })
       when is_binary(old_nick) and is_binary(new_nick) do
    now = DateTime.utc_now(:second)

    from(u in ChannelUser,
      where: u.channel_membership_id == ^membership.id and u.nick == ^old_nick
    )
    |> Repo.update_all(set: [nick: new_nick, last_observed_at: now, updated_at: now])
  end

  defp apply_presence_diff(%ChannelMembership{} = membership, %{
         action: "away",
         nick: nick,
         status: status
       })
       when is_binary(nick) and is_binary(status) do
    update_channel_user(membership, nick, %{status: status})
  end

  defp apply_presence_diff(%ChannelMembership{} = membership, %{
         action: "role",
         nick: nick,
         role: role
       })
       when is_binary(nick) and is_binary(role) do
    update_channel_user(membership, nick, %{role: role})
  end

  defp apply_presence_diff(_membership, _diff), do: :ok

  defp upsert_channel_user(%ChannelMembership{} = membership, user) do
    now = DateTime.utc_now(:second)

    attrs =
      user
      |> channel_user_attrs(now)
      |> Map.merge(%{
        channel_membership_id: membership.id,
        inserted_at: now,
        updated_at: now
      })

    Repo.insert_all(ChannelUser, [attrs],
      on_conflict: {:replace, [:role, :status, :hostmask, :last_observed_at, :updated_at]},
      conflict_target: [:channel_membership_id, :nick]
    )
  end

  defp update_channel_user(%ChannelMembership{} = membership, nick, attrs) do
    now = DateTime.utc_now(:second)

    updates =
      attrs
      |> Map.take([:role, :status, :hostmask])
      |> Map.put(:last_observed_at, now)
      |> Map.put(:updated_at, now)
      |> Map.to_list()

    from(u in ChannelUser, where: u.channel_membership_id == ^membership.id and u.nick == ^nick)
    |> Repo.update_all(set: updates)
  end

  defp channel_user_attrs(user, observed_at) do
    %{
      nick: metadata_value(user, :nick),
      role: metadata_value(user, :role) || "user",
      status: metadata_value(user, :status) || "online",
      hostmask: metadata_value(user, :hostmask),
      last_observed_at: metadata_value(user, :last_observed_at) || observed_at
    }
  end

  defp pubsub_event(%{type: "buffer:error"}), do: :buffer_error
  defp pubsub_event(%{type: "buffer:system"}), do: :buffer_system
  defp pubsub_event(_event), do: :buffer_message

  defp channel_membership(connection, channel, casemapping, status \\ nil) do
    query =
      from(m in ChannelMembership,
        where: m.server_connection_id == ^connection.id
      )

    query = if status, do: where(query, [m], m.status == ^status), else: query
    key = channel_key(channel, casemapping)

    query
    |> Repo.all()
    |> Enum.find(&(channel_key(&1.channel, casemapping) == key))
  end

  def reconcile_channel_memberships(%ServerConnection{} = connection, casemapping) do
    case Repo.transaction(fn ->
           lock_memberships(connection)
           reconcile_channel_memberships_locked(connection, casemapping)
         end) do
      {:ok, losers} ->
        Enum.each(losers, &broadcast_reconciled_membership(&1, connection))
        {:ok, losers}

      error ->
        error
    end
  end

  defp lock_memberships(connection) do
    ServerConnection
    |> where([server], server.id == ^connection.id)
    |> lock("FOR UPDATE")
    |> Repo.one!()

    ChannelMembership
    |> where([membership], membership.server_connection_id == ^connection.id)
    |> lock("FOR UPDATE")
    |> Repo.all()
  end

  defp reconcile_channel_memberships_locked(connection, casemapping) do
    losers =
      connection
      |> all_channel_memberships()
      |> Enum.group_by(&channel_key(&1.channel, casemapping))
      |> Enum.flat_map(fn {_key, memberships} -> merge_equivalent_memberships(memberships) end)

    losers
  end

  defp all_channel_memberships(connection) do
    ChannelMembership
    |> where([membership], membership.server_connection_id == ^connection.id)
    |> order_by([membership], asc: membership.id)
    |> Repo.all()
  end

  defp merge_equivalent_memberships([_membership]), do: []

  defp merge_equivalent_memberships(memberships) do
    winner = Enum.min_by(memberships, &{membership_status_rank(&1.status), &1.id})
    losers = Enum.reject(memberships, &(&1.id == winner.id))

    Enum.each(losers, fn loser ->
      from(message in Message, where: message.channel_membership_id == ^loser.id)
      |> Repo.update_all(set: [channel_membership_id: winner.id])

      from(notification in Notification, where: notification.channel_membership_id == ^loser.id)
      |> Repo.update_all(set: [channel_membership_id: winner.id])

      loser
      |> list_channel_users()
      |> Enum.each(&upsert_channel_user(winner, &1))

      Repo.delete!(loser)
    end)

    merged_status = winner.status

    winner
    |> ChannelMembership.changeset(%{
      auto_join: Enum.any?(memberships, & &1.auto_join),
      unread_count: Enum.reduce(memberships, 0, &(&1.unread_count + &2)),
      mention_count: Enum.reduce(memberships, 0, &(&1.mention_count + &2)),
      joined_at:
        memberships
        |> Enum.map(& &1.joined_at)
        |> Enum.reject(&is_nil/1)
        |> Enum.min(fn -> nil end),
      left_at:
        if(merged_status in ["joined", "pending"],
          do: nil,
          else:
            memberships
            |> Enum.map(& &1.left_at)
            |> Enum.reject(&is_nil/1)
            |> Enum.max(fn -> nil end)
        )
    })
    |> Repo.update!()

    losers
  end

  defp broadcast_reconciled_membership(loser, connection) do
    broadcast_buffer_left(%{
      user_id: connection.user_id,
      buffer_id: "channel:#{loser.id}",
      server_connection_id: connection.id,
      channel_membership_id: loser.id,
      channel: loser.channel
    })
  end

  defp membership_status_rank("joined"), do: 0
  defp membership_status_rank("pending"), do: 1
  defp membership_status_rank("left"), do: 2
  defp membership_status_rank("error"), do: 3

  defp stored_casemapping(%ServerConnection{casemapping: mapping}) when is_binary(mapping) do
    case mapping do
      "ascii" -> :ascii
      "strict_rfc1459" -> :strict_rfc1459
      _mapping -> :rfc1459
    end
  end

  defp stored_casemapping(%ServerConnection{}), do: nil

  defp presence_memberships(connection, channel),
    do: presence_memberships(connection, channel, :rfc1459)

  defp presence_memberships(connection, nil, _casemapping) do
    ChannelMembership
    |> where([m], m.server_connection_id == ^connection.id and m.status == "joined")
    |> Repo.all()
  end

  defp presence_memberships(connection, channel, casemapping) do
    case channel_membership(connection, channel, casemapping, "joined") do
      %ChannelMembership{} = membership -> [membership]
      nil -> []
    end
  end

  defp presence_memberships_with_nick(connection, nick) do
    ChannelMembership
    |> join(:inner, [m], u in ChannelUser, on: u.channel_membership_id == m.id)
    |> where(
      [m, u],
      m.server_connection_id == ^connection.id and m.status == "joined" and
        fragment("lower(?)", u.nick) == fragment("lower(?)", ^nick)
    )
    |> Repo.all()
  end

  defp role_for_prefixes(prefixes) do
    cond do
      "~" in prefixes -> "owner"
      "&" in prefixes -> "admin"
      "@" in prefixes -> "op"
      "%" in prefixes -> "halfop"
      "+" in prefixes -> "voice"
      true -> "user"
    end
  end

  defp to_int(value, _default) when is_integer(value), do: value

  defp to_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> default
    end
  end

  defp to_int(_, default), do: default
end
