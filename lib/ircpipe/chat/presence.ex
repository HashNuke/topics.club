defmodule Ircpipe.Chat.Presence do
  @moduledoc false

  import Ecto.Query

  alias Ircpipe.Chat.{
    ChannelMembership,
    ChannelUser,
    PresenceDiff,
    PresenceMembershipLookup,
    PresenceQueries,
    ServerConnection,
    ServerConnectionLock
  }

  alias Ircpipe.Irc.Identifier
  alias Ircpipe.Realtime.Event
  alias Ircpipe.Repo

  defdelegate list_users(membership), to: PresenceQueries

  def sync(%ServerConnection{} = connection, channel, names, casemapping) do
    assert_no_outer_transaction!()

    Repo.transaction(fn ->
      active_connection = ServerConnectionLock.lock_active!(connection.id)

      case PresenceMembershipLookup.find(active_connection, channel, casemapping) do
        %ChannelMembership{} = membership ->
          users =
            names
            |> Enum.map(&presence_user(&1, casemapping))
            |> Enum.reverse()
            |> Enum.uniq_by(& &1.nick_key)
            |> Enum.reverse()

          replace_users(membership, users)

          event =
            Event.presence_sync(%{
              buffer_id: "channel:#{membership.id}",
              server_connection_id: active_connection.id,
              channel_membership_id: membership.id,
              users: users
            })

          {:publish, active_connection.user_id, event}

        nil ->
          :noop
      end
    end)
    |> case do
      {:ok, {:publish, user_id, event}} ->
        _effects =
          ServerConnectionLock.serialize_effects(connection.id, fn _active_connection ->
            Phoenix.PubSub.broadcast(
              Ircpipe.PubSub,
              "user:#{user_id}",
              {:presence_sync, event}
            )
          end)

        :ok

      {:ok, :noop} ->
        :ok

      error ->
        error
    end
  end

  def diff(%ServerConnection{} = connection, channel, diff, casemapping) do
    assert_no_outer_transaction!()
    canonical_diff = PresenceDiff.canonicalize(diff, casemapping)

    Repo.transaction(fn ->
      active_connection = ServerConnectionLock.lock_active!(connection.id)

      events =
        active_connection
        |> PresenceMembershipLookup.list(channel, casemapping)
        |> Enum.map(fn membership ->
          apply_diff(membership, canonical_diff)

          Event.presence_diff(%{
            buffer_id: "channel:#{membership.id}",
            server_connection_id: active_connection.id,
            channel_membership_id: membership.id,
            diff: canonical_diff
          })
        end)

      {active_connection.user_id, events}
    end)
    |> case do
      {:ok, {user_id, events}} ->
        _effects =
          ServerConnectionLock.serialize_effects(connection.id, fn _active_connection ->
            Enum.each(events, fn event ->
              Phoenix.PubSub.broadcast(
                Ircpipe.PubSub,
                "user:#{user_id}",
                {:presence_diff, event}
              )
            end)
          end)

        :ok

      error ->
        error
    end
  end

  def merge_users(%ChannelMembership{} = source, %ChannelMembership{} = destination) do
    source
    |> list_users()
    |> Enum.each(&upsert_user(destination, &1))
  end

  def rekey_users(%ServerConnection{} = connection, casemapping) do
    unless Repo.in_transaction?() do
      raise ArgumentError, "presence rekeying requires a database transaction"
    end

    ChannelUser
    |> join(:inner, [user], membership in ChannelMembership,
      on: membership.id == user.channel_membership_id
    )
    |> where([_user, membership], membership.server_connection_id == ^connection.id)
    |> order_by([user], asc: user.id)
    |> Repo.all()
    |> Enum.group_by(fn user ->
      {user.channel_membership_id, Identifier.key(user.nick, casemapping)}
    end)
    |> Enum.each(fn {{_membership_id, nick_key}, equivalent_users} ->
      winner =
        Enum.max_by(equivalent_users, fn user ->
          {DateTime.to_unix(user.last_observed_at, :microsecond), user.id}
        end)

      loser_ids = equivalent_users |> Enum.reject(&(&1.id == winner.id)) |> Enum.map(& &1.id)

      if loser_ids != [] do
        from(user in ChannelUser, where: user.id in ^loser_ids)
        |> Repo.delete_all()
      end

      if winner.nick_key != nick_key do
        winner
        |> Ecto.Changeset.change(nick_key: nick_key)
        |> Repo.update!()
      end
    end)

    :ok
  end

  defp presence_user(name, casemapping) do
    %{
      nick: name.nick,
      nick_key: Identifier.key(name.nick, casemapping),
      role: role_for_prefixes(Map.get(name, :prefixes, [])),
      status: "online",
      hostmask: Map.get(name, :raw_source),
      last_observed_at: DateTime.utc_now(:second)
    }
  end

  defp replace_users(%ChannelMembership{} = membership, users) do
    now = DateTime.utc_now(:second)

    from(user in ChannelUser, where: user.channel_membership_id == ^membership.id)
    |> Repo.delete_all()

    entries =
      Enum.map(users, fn user ->
        user
        |> user_attrs(now)
        |> Map.merge(%{
          channel_membership_id: membership.id,
          inserted_at: now,
          updated_at: now
        })
      end)

    if entries != [], do: Repo.insert_all(ChannelUser, entries)
  end

  defp apply_diff(%ChannelMembership{} = membership, %{action: "join", user: user}) do
    upsert_user(membership, user)
  end

  defp apply_diff(%ChannelMembership{} = membership, %{action: action, nick_key: nick_key})
       when action in ["part", "quit"] and is_binary(nick_key) do
    from(
      user in ChannelUser,
      where: user.channel_membership_id == ^membership.id and user.nick_key == ^nick_key
    )
    |> Repo.delete_all()
  end

  defp apply_diff(%ChannelMembership{} = membership, %{
         action: "nick",
         old_nick_key: old_nick_key,
         new_nick: new_nick,
         new_nick_key: new_nick_key
       })
       when is_binary(old_nick_key) and is_binary(new_nick) and is_binary(new_nick_key) do
    now = DateTime.utc_now(:second)

    from(
      user in ChannelUser,
      where: user.channel_membership_id == ^membership.id and user.nick_key == ^old_nick_key
    )
    |> Repo.update_all(
      set: [
        nick: new_nick,
        nick_key: new_nick_key,
        last_observed_at: now,
        updated_at: now
      ]
    )
  end

  defp apply_diff(%ChannelMembership{} = membership, %{
         action: "away",
         nick_key: nick_key,
         status: status
       })
       when is_binary(nick_key) and is_binary(status) do
    update_user(membership, nick_key, %{status: status})
  end

  defp apply_diff(%ChannelMembership{} = membership, %{
         action: "role",
         nick_key: nick_key,
         role: role
       })
       when is_binary(nick_key) and is_binary(role) do
    update_user(membership, nick_key, %{role: role})
  end

  defp apply_diff(_membership, _diff), do: :ok

  defp upsert_user(%ChannelMembership{} = membership, user) do
    now = DateTime.utc_now(:second)

    attrs =
      user
      |> user_attrs(now)
      |> Map.merge(%{
        channel_membership_id: membership.id,
        inserted_at: now,
        updated_at: now
      })

    Repo.insert_all(ChannelUser, [attrs],
      on_conflict: {:replace, [:nick, :role, :status, :hostmask, :last_observed_at, :updated_at]},
      conflict_target: [:channel_membership_id, :nick_key]
    )
  end

  defp update_user(%ChannelMembership{} = membership, nick_key, attrs) do
    now = DateTime.utc_now(:second)

    updates =
      attrs
      |> Map.take([:role, :status, :hostmask])
      |> Map.put(:last_observed_at, now)
      |> Map.put(:updated_at, now)
      |> Map.to_list()

    from(
      user in ChannelUser,
      where: user.channel_membership_id == ^membership.id and user.nick_key == ^nick_key
    )
    |> Repo.update_all(set: updates)
  end

  defp user_attrs(user, observed_at) do
    %{
      nick: value(user, :nick),
      nick_key: value(user, :nick_key),
      role: value(user, :role) || "user",
      status: value(user, :status) || "online",
      hostmask: value(user, :hostmask),
      last_observed_at: value(user, :last_observed_at) || observed_at
    }
  end

  defp value(metadata, key) do
    Map.get(metadata, key) || Map.get(metadata, Atom.to_string(key))
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

  defp assert_no_outer_transaction! do
    if Repo.in_transaction?() do
      raise ArgumentError, "cannot mutate presence inside an existing transaction"
    end
  end
end
