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

  def list_topics do
    Topic
    |> order_by([t], asc: t.sort_order, asc: t.name)
    |> Repo.all()
  end

  def get_topic!(id), do: Repo.get!(Topic, id)

  def list_connections(%User{id: user_id}) do
    ServerConnection
    |> where([c], c.user_id == ^user_id)
    |> preload(:channel_memberships)
    |> order_by([c], asc: c.name)
    |> Repo.all()
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
      {:ok, membership} = join_channel(user, connection, topic.channel)

      %{connection: connection, membership: membership, topic: topic}
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

  def join_channel(
        %User{id: user_id} = user,
        %ServerConnection{user_id: user_id} = connection,
        channel
      ) do
    attrs = %{channel: normalize_channel(channel), joined_at: DateTime.utc_now(:second)}

    result =
      case Repo.get_by(ChannelMembership,
             server_connection_id: connection.id,
             channel: attrs.channel
           ) do
        %ChannelMembership{} = membership ->
          membership
          |> ChannelMembership.changeset(%{joined_at: attrs.joined_at})
          |> Repo.update()

        nil ->
          result =
            %ChannelMembership{user_id: user.id, server_connection_id: connection.id}
            |> ChannelMembership.changeset(attrs)
            |> Repo.insert()

          with {:ok, membership} <- result do
            broadcast_buffer_joined(connection, membership)
          end

          result
      end

    with {:ok, membership} <- result do
      {:ok, membership}
    end
  end

  def join_channel(%User{}, %ServerConnection{}, _channel), do: {:error, :invalid_connection}

  def get_membership!(%User{id: user_id}, id) do
    ChannelMembership
    |> where([m], m.user_id == ^user_id and m.id == ^id)
    |> preload(:server_connection)
    |> Repo.one!()
  end

  def get_membership_by_channel!(%User{id: user_id}, %ServerConnection{} = connection, channel) do
    ChannelMembership
    |> where(
      [m],
      m.user_id == ^user_id and m.server_connection_id == ^connection.id and
        m.channel == ^normalize_channel(channel)
    )
    |> preload(:server_connection)
    |> Repo.one!()
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

  def record_inbound_message(
        %ServerConnection{} = connection,
        channel,
        nick,
        body,
        kind \\ "message",
        metadata \\ %{}
      ) do
    membership =
      Repo.get_by!(ChannelMembership,
        server_connection_id: connection.id,
        channel: normalize_channel(channel)
      )

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

  def record_channel_system_message(%ServerConnection{} = connection, channel, kind, nick, body) do
    membership =
      Repo.get_by!(ChannelMembership,
        server_connection_id: connection.id,
        channel: normalize_channel(channel)
      )

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

  def broadcast_presence_sync(%ServerConnection{} = connection, channel, names) do
    case Repo.get_by(ChannelMembership,
           server_connection_id: connection.id,
           channel: normalize_channel(channel)
         ) do
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

  def broadcast_presence_diff(%ServerConnection{} = connection, channel, diff) do
    connection
    |> presence_memberships(channel)
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
    broadcast_buffer_left(%{
      user_id: user_id,
      buffer_id: "channel:#{membership.id}",
      server_connection_id: membership.server_connection_id,
      channel_membership_id: membership.id
    })

    from(m in ChannelMembership, where: m.id == ^membership.id and m.user_id == ^user_id)
    |> Repo.delete_all()

    :ok
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

  defp presence_memberships(connection, nil) do
    ChannelMembership
    |> where([m], m.server_connection_id == ^connection.id)
    |> Repo.all()
  end

  defp presence_memberships(connection, channel) do
    case Repo.get_by(ChannelMembership,
           server_connection_id: connection.id,
           channel: normalize_channel(channel)
         ) do
      %ChannelMembership{} = membership -> [membership]
      nil -> []
    end
  end

  defp presence_memberships_with_nick(connection, nick) do
    ChannelMembership
    |> join(:inner, [m], u in ChannelUser, on: u.channel_membership_id == m.id)
    |> where(
      [m, u],
      m.server_connection_id == ^connection.id and
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
