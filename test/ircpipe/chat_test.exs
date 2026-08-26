defmodule Ircpipe.ChatTest do
  use Ircpipe.DataCase, async: true

  alias Ircpipe.AccountsFixtures
  alias Ircpipe.Chat
  alias Ircpipe.Chat.{ChannelMembership, Message, MessageHistory}
  alias Ircpipe.Chat.Topic
  alias Ircpipe.Repo

  test "scopes server connections to their owner" do
    user = AccountsFixtures.user_fixture()
    other_user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Chat.create_connection(user, %{
        "name" => "local",
        "host" => "127.0.0.1",
        "port" => 6667,
        "use_tls" => false,
        "nickname" => "mira"
      })

    assert [owned] = Chat.list_connections(user)
    assert owned.id == connection.id
    assert [] = Chat.list_connections(other_user)
    assert_raise Ecto.NoResultsError, fn -> Chat.get_connection!(other_user, connection.id) end
  end

  test "gets an existing connection by normalized endpoint and port instead of display name" do
    user = AccountsFixtures.user_fixture()

    {:ok, existing} =
      Chat.create_connection(user, %{
        "name" => "My Libera connection",
        "host" => "IRC.Libera.Chat",
        "port" => 6697,
        "use_tls" => true
      })

    assert {:ok, reused} =
             Chat.create_or_get_connection(user, %{
               "name" => "Libera.Chat",
               "host" => "irc.libera.chat",
               "port" => 6697,
               "use_tls" => false
             })

    assert reused.id == existing.id

    assert {:ok, other_port} =
             Chat.create_or_get_connection(user, %{
               "name" => "Libera alternate port",
               "host" => "irc.libera.chat",
               "port" => 6667,
               "use_tls" => false
             })

    refute other_port.id == existing.id
  end

  test "defaults nickname and SASL account while retaining connection credentials" do
    user = AccountsFixtures.user_fixture(%{email: "mira@example.com"})

    {:ok, connection} =
      Chat.create_connection(user, %{
        "name" => "authenticated",
        "host" => "irc.example.com",
        "nickname" => " ",
        "sasl_password" => "account-secret",
        "server_password" => "network-secret"
      })

    stored_connection = Repo.get!(Ircpipe.Chat.ServerConnection, connection.id)

    assert stored_connection.nickname == "mira"
    assert stored_connection.sasl_username == "mira"
    assert stored_connection.sasl_password == "account-secret"
    assert stored_connection.server_password == "network-secret"

    assert %{rows: [[encrypted_server_password, encrypted_sasl_password]]} =
             Repo.query!(
               "SELECT server_password, sasl_password FROM server_connections WHERE id = $1",
               [connection.id]
             )

    refute encrypted_server_password == "network-secret"
    refute encrypted_sasl_password == "account-secret"
    assert Ircpipe.Vault.decrypt!(encrypted_server_password) == "network-secret"
    assert Ircpipe.Vault.decrypt!(encrypted_sasl_password) == "account-secret"
  end

  test "defaults the SASL account in atom-keyed connection attributes" do
    user = AccountsFixtures.user_fixture(%{email: "mira@example.com"})

    assert {:ok, connection} =
             Chat.create_connection(user, %{
               name: "authenticated",
               host: "irc.example.com",
               nickname: "mira",
               sasl_password: "account-secret"
             })

    assert connection.sasl_username == "mira"
  end

  test "lists bouncer connections by user activity" do
    active_user = AccountsFixtures.user_fixture()
    inactive_user = AccountsFixtures.user_fixture()
    cutoff = DateTime.add(DateTime.utc_now(:second), -24, :hour)

    Repo.update_all(
      from(u in Ircpipe.Accounts.User, where: u.id == ^active_user.id),
      set: [last_seen_at: DateTime.add(cutoff, 1, :second)]
    )

    Repo.update_all(
      from(u in Ircpipe.Accounts.User, where: u.id == ^inactive_user.id),
      set: [last_seen_at: DateTime.add(cutoff, -1, :second)]
    )

    {:ok, active_connection} =
      Chat.create_connection(active_user, %{
        "name" => "active",
        "host" => "127.0.0.1",
        "port" => 6667,
        "use_tls" => false,
        "nickname" => "active",
        "status" => "connected"
      })

    {:ok, inactive_connection} =
      Chat.create_connection(inactive_user, %{
        "name" => "inactive",
        "host" => "127.0.0.1",
        "port" => 6667,
        "use_tls" => false,
        "nickname" => "inactive",
        "status" => "connected"
      })

    assert Enum.map(Chat.list_recently_seen_connections(cutoff), & &1.id) == [
             active_connection.id
           ]

    assert Enum.map(Chat.list_inactive_connections(cutoff), & &1.id) == [inactive_connection.id]
  end

  test "suggested topic joins generate IRC-safe nicknames" do
    user = AccountsFixtures.user_fixture(%{email: "3dev@example.com"})

    topic =
      Repo.insert!(
        Topic.changeset(%Topic{}, %{
          name: "#elixir",
          description: "Local Elixir discussion.",
          server_host: "127.0.0.1",
          server_port: 6669,
          use_tls: false,
          channel: "#elixir",
          sort_order: 10
        })
      )

    {:ok, %{connection: connection}} = Chat.join_topic(user, topic)

    assert connection.nickname == "u_3dev"
    assert Chat.valid_nick?(connection.nickname)
  end

  test "suggested topic joins repair existing invalid nicknames" do
    user = AccountsFixtures.user_fixture(%{email: "3dev@example.com"})

    {:ok, connection} =
      Chat.create_connection(user, %{
        "name" => "127.0.0.1",
        "host" => "127.0.0.1",
        "port" => 6669,
        "use_tls" => false,
        "nickname" => "3dev",
        "status" => "connecting"
      })

    topic =
      Repo.insert!(
        Topic.changeset(%Topic{}, %{
          name: "#elixir",
          description: "Local Elixir discussion.",
          server_host: "127.0.0.1",
          server_port: 6669,
          use_tls: false,
          channel: "#elixir",
          sort_order: 10
        })
      )

    {:ok, %{connection: repaired}} = Chat.join_topic(user, topic)

    assert repaired.id == connection.id
    assert repaired.nickname == "u_3dev"
    assert repaired.status == "disconnected"
  end

  test "does not join channels on another user's server connection" do
    user = AccountsFixtures.user_fixture()
    other_user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Chat.create_connection(other_user, %{
        "name" => "local",
        "host" => "127.0.0.1",
        "port" => 6667,
        "use_tls" => false,
        "nickname" => "mira"
      })

    assert {:error, :invalid_connection} = Chat.join_channel(user, connection, "#private")
  end

  test "keeps membership identity and history across confirmed join and part lifecycle" do
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Chat.create_connection(user, %{
        "name" => "local",
        "host" => "127.0.0.1",
        "port" => 6667,
        "use_tls" => false,
        "nickname" => "mira"
      })

    {:ok, pending} = Chat.request_channel_join(user, connection, "#elixir")
    assert pending.status == "pending"
    assert pending.auto_join

    {:ok, joined} = Chat.confirm_channel_join(connection, "#elixir")
    assert joined.id == pending.id
    assert joined.status == "joined"
    assert joined.joined_at

    {:ok, duplicate_confirmation} = Chat.confirm_channel_join(connection, "#elixir")
    assert duplicate_confirmation.joined_at == joined.joined_at

    Chat.record_inbound_message(connection, "#elixir", "akash", "history survives")

    {:ok, left} = Chat.confirm_channel_left(connection, "#elixir")
    assert left.id == pending.id
    assert left.status == "left"
    refute left.auto_join
    assert left.left_at
    assert [%Message{body: "history survives"}] = MessageHistory.list_messages(user, left.id)

    {:ok, duplicate_left} = Chat.confirm_channel_left(connection, "#elixir")
    assert duplicate_left.left_at == left.left_at

    Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{user.id}")
    {:ok, rejoining} = Chat.request_channel_join(user, connection, "#elixir")
    assert rejoining.id == pending.id
    assert rejoining.status == "pending"
    assert rejoining.auto_join
    assert rejoining.joined_at == joined.joined_at

    {:ok, rejected} = Chat.reject_channel_join(connection, "#elixir", "invite only")
    assert rejected.status == "error"
    refute rejected.auto_join
    assert rejected.last_error == "invite only"
    assert rejected.joined_at == joined.joined_at

    assert_receive {:buffer_left,
                    %{buffer_id: "channel:" <> _, channel_membership_id: membership_id}}

    assert membership_id == pending.id
  end

  test "reuses memberships under negotiated IRC channel casemapping" do
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Chat.create_connection(user, %{
        "name" => "casemapping",
        "host" => "localhost",
        "port" => 6667,
        "use_tls" => false,
        "nickname" => "mira"
      })

    {:ok, ascii_pending} = Chat.request_channel_join(user, connection, "#Pipe", :ascii)
    {:ok, ascii_joined} = Chat.confirm_channel_join(connection, "#pipe", :ascii)
    assert ascii_joined.id == ascii_pending.id

    {:ok, rfc_pending} = Chat.request_channel_join(user, connection, "#[Ops]", :rfc1459)
    {:ok, rfc_joined} = Chat.confirm_channel_join(connection, "#" <> "{ops}", :rfc1459)
    assert rfc_joined.id == rfc_pending.id

    assert Chat.get_channel_membership(connection, "#PIPE", :ascii).id == ascii_pending.id

    assert Chat.get_channel_membership(connection, "#" <> "{OPS}", :rfc1459).id ==
             rfc_pending.id
  end

  test "reconciles casemapping-equivalent memberships without losing history" do
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Chat.create_connection(user, %{
        "name" => "duplicate-casemapping",
        "host" => "localhost",
        "port" => 6667,
        "use_tls" => false,
        "nickname" => "mira"
      })

    {:ok, first} = Chat.join_channel(user, connection, "#[Ops]")

    second =
      %ChannelMembership{user_id: user.id, server_connection_id: connection.id}
      |> ChannelMembership.changeset(%{
        channel: "#" <> "{ops}",
        status: "joined",
        auto_join: true
      })
      |> Repo.insert!()

    Chat.record_inbound_message(
      connection,
      "#[Ops]",
      "mira",
      "first history",
      "message",
      %{},
      :ascii
    )

    Chat.record_inbound_message(
      connection,
      "#" <> "{ops}",
      "mira",
      "second history",
      "message",
      %{},
      :ascii
    )

    Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{user.id}")
    assert {:ok, [_loser]} = Chat.reconcile_channel_memberships(connection, :rfc1459)
    assert_receive {:buffer_left, %{channel_membership_id: loser_id}}
    assert loser_id in [first.id, second.id]
    membership = Chat.get_channel_membership(connection, "#" <> "{OPS}", :rfc1459)
    assert membership.id in [first.id, second.id]

    assert Enum.map(MessageHistory.list_messages(user, membership.id), & &1.body) == [
             "first history",
             "second history"
           ]

    memberships = Repo.all(ChannelMembership)
    assert Enum.count(memberships, &(&1.server_connection_id == connection.id)) == 1
  end

  test "does not reconcile bracket-equivalent memberships before casemapping is trusted" do
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Chat.create_connection(user, %{
        "name" => "unknown-casemapping",
        "host" => "localhost",
        "port" => 6667,
        "use_tls" => false,
        "nickname" => "mira"
      })

    Enum.each(["#[ops]", "#" <> "{ops}"], fn channel ->
      %ChannelMembership{user_id: user.id, server_connection_id: connection.id}
      |> ChannelMembership.changeset(%{channel: channel, status: "joined", auto_join: true})
      |> Repo.insert!()
    end)

    assert connection.casemapping == nil
    assert [%{channel_memberships: memberships}] = Chat.list_connections(user)
    assert Enum.count(memberships) == 2

    {:ok, ascii_connection} = Chat.update_connection_casemapping(connection, :ascii)
    assert {:ok, []} = Chat.reconcile_channel_memberships(ascii_connection, :ascii)
    assert [%{channel_memberships: memberships}] = Chat.list_connections(user)
    assert Enum.count(memberships) == 2
  end

  test "scopes channel memberships and buffer history to their owner" do
    user = AccountsFixtures.user_fixture()
    other_user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Chat.create_connection(user, %{
        "name" => "local",
        "host" => "127.0.0.1",
        "port" => 6667,
        "use_tls" => false,
        "nickname" => "mira"
      })

    {:ok, membership} = Chat.join_channel(user, connection, "#elixir")
    Chat.record_inbound_message(connection, "#elixir", "akash", "scoped")

    assert Chat.get_membership!(user, membership.id).id == membership.id
    assert Chat.get_membership_by_channel!(user, connection, "#elixir").id == membership.id

    assert [%Message{body: "scoped"}] =
             MessageHistory.list_buffer_messages(user, "channel:#{membership.id}")

    assert_raise Ecto.NoResultsError, fn -> Chat.get_membership!(other_user, membership.id) end

    assert_raise Ecto.NoResultsError, fn ->
      Chat.get_membership_by_channel!(other_user, connection, "#elixir")
    end

    assert_raise Ecto.NoResultsError, fn ->
      MessageHistory.list_buffer_messages(other_user, "channel:#{membership.id}")
    end
  end

  test "prunes messages older than the user's retention window after inbound persistence" do
    user = AccountsFixtures.user_fixture()
    {:ok, user} = Chat.update_retention_days(user, 1)

    {:ok, connection} =
      Chat.create_connection(user, %{
        "name" => "local",
        "host" => "127.0.0.1",
        "port" => 6667,
        "use_tls" => false,
        "nickname" => "mira"
      })

    {:ok, membership} = Chat.join_channel(user, connection, "#elixir")

    expired =
      %Message{
        user_id: user.id,
        server_connection_id: connection.id,
        channel_membership_id: membership.id
      }
      |> Message.changeset(%{
        kind: "message",
        nick: "akash",
        body: "old",
        occurred_at: DateTime.add(DateTime.utc_now(:second), -2, :day)
      })
      |> Repo.insert!()

    Chat.record_inbound_message(connection, "#elixir", "akash", "new")

    assert is_nil(Repo.get(Message, expired.id))
    assert [%Message{body: "new"}] = MessageHistory.list_messages(user, membership.id)
  end

  test "records server buffer messages without a channel membership" do
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Chat.create_connection(user, %{
        "name" => "local",
        "host" => "127.0.0.1",
        "port" => 6667,
        "use_tls" => false,
        "nickname" => "mira"
      })

    Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{user.id}")

    assert {:ok, %Message{channel_membership_id: nil, kind: "system", body: "Connected"}} =
             Chat.record_server_message(connection, "Connected")

    assert_receive {:buffer_system,
                    %{
                      type: "buffer:system",
                      version: 1,
                      event_id: "message:" <> _,
                      buffer_id: "server:" <> _,
                      server_connection_id: connection_id,
                      channel_membership_id: nil,
                      kind: "system",
                      body: "Connected"
                    }}

    assert connection_id == connection.id

    assert [%Message{body: "Connected"}] =
             MessageHistory.list_buffer_messages(user, "server:#{connection.id}")

    assert Chat.get_connection!(user, connection.id).unread_count == 1
  end

  test "marks server buffers read" do
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Chat.create_connection(user, %{
        "name" => "local",
        "host" => "127.0.0.1",
        "port" => 6667,
        "use_tls" => false,
        "nickname" => "mira"
      })

    Chat.record_server_message(connection, "Connected")
    Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{user.id}")

    assert :ok = Chat.mark_read(user, Chat.get_connection!(user, connection.id))

    assert_receive {:buffer_read,
                    %{
                      type: "buffer:read",
                      buffer_id: buffer_id,
                      server_connection_id: connection_id,
                      channel_membership_id: nil,
                      unread_count: 0,
                      mention_count: 0
                    }}

    assert buffer_id == "server:#{connection.id}"
    assert connection_id == connection.id

    reloaded = Chat.get_connection!(user, connection.id)
    assert reloaded.unread_count == 0
    assert reloaded.mention_count == 0
  end

  test "broadcasts server errors as buffer error events" do
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Chat.create_connection(user, %{
        "name" => "local",
        "host" => "127.0.0.1",
        "port" => 6667,
        "use_tls" => false,
        "nickname" => "mira"
      })

    Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{user.id}")

    assert {:ok, %Message{kind: "error", body: "Connection failed"}} =
             Chat.record_server_message(connection, "Connection failed", "error")

    assert_receive {:buffer_error,
                    %{
                      type: "buffer:error",
                      version: 1,
                      event_id: "message:" <> _,
                      buffer_id: "server:" <> _,
                      server_connection_id: connection_id,
                      kind: "error",
                      body: "Connection failed"
                    }}

    assert connection_id == connection.id
  end

  test "broadcasts channel system lines as buffer system events" do
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Chat.create_connection(user, %{
        "name" => "local",
        "host" => "127.0.0.1",
        "port" => 6667,
        "use_tls" => false,
        "nickname" => "mira"
      })

    {:ok, membership} = Chat.join_channel(user, connection, "#elixir")
    Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{user.id}")

    assert {:ok, _message} =
             Chat.record_channel_system_message(
               connection,
               "#elixir",
               "join",
               "akash",
               "akash joined #elixir."
             )

    assert_receive {:buffer_system,
                    %{
                      type: "buffer:system",
                      version: 1,
                      event_id: "message:" <> _,
                      buffer_id: buffer_id,
                      server_connection_id: connection_id,
                      channel_membership_id: membership_id,
                      kind: "join",
                      body: "akash joined #elixir."
                    }}

    assert buffer_id == "channel:#{membership.id}"
    assert connection_id == connection.id
    assert membership_id == membership.id
  end

  test "broadcasts newly joined channel buffers" do
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Chat.create_connection(user, %{
        "name" => "local",
        "host" => "127.0.0.1",
        "port" => 6667,
        "use_tls" => false,
        "nickname" => "mira"
      })

    Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{user.id}")

    assert {:ok, membership} = Chat.join_channel(user, connection, "#elixir")

    assert_receive {:buffer_joined,
                    %{
                      type: "buffer:joined",
                      version: 1,
                      event_id: "buffer_joined:channel:" <> _,
                      buffer: %{
                        buffer_id: buffer_id,
                        buffer_type: "channel",
                        title: "#elixir",
                        server_connection_id: connection_id,
                        channel_membership_id: membership_id
                      },
                      connection: %{id: connection_id}
                    }}

    assert buffer_id == "channel:#{membership.id}"
    assert connection_id == connection.id
    assert membership_id == membership.id

    assert {:ok, _membership} = Chat.join_channel(user, connection, "#elixir")
    refute_receive {:buffer_joined, _payload}, 100
  end

  test "stores channel user lists from presence sync and diffs" do
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Chat.create_connection(user, %{
        "name" => "local",
        "host" => "127.0.0.1",
        "port" => 6667,
        "use_tls" => false,
        "nickname" => "mira"
      })

    {:ok, membership} = Chat.join_channel(user, connection, "#elixir")

    Chat.broadcast_presence_sync(connection, "#elixir", [
      %{nick: "mira", prefixes: ["@"], raw_source: "mira!user@example.test"},
      %{nick: "akash", prefixes: []}
    ])

    assert [
             %{
               nick: "akash",
               role: "user",
               status: "online",
               last_observed_at: %DateTime{}
             },
             %{
               nick: "mira",
               role: "op",
               status: "online",
               hostmask: "mira!user@example.test",
               last_observed_at: %DateTime{}
             }
           ] = Chat.list_channel_users(membership)

    Chat.broadcast_presence_diff(connection, "#elixir", %{
      action: "away",
      nick: "akash",
      status: "away"
    })

    assert Enum.any?(
             Chat.list_channel_users(membership),
             &(&1.nick == "akash" and &1.status == "away")
           )

    Chat.broadcast_presence_diff(connection, "#elixir", %{
      action: "role",
      nick: "akash",
      role: "voice"
    })

    assert Enum.any?(
             Chat.list_channel_users(membership),
             &(&1.nick == "akash" and &1.role == "voice")
           )

    Chat.broadcast_presence_diff(connection, "#elixir", %{
      action: "nick",
      old_nick: "akash",
      new_nick: "ak"
    })

    assert Enum.any?(Chat.list_channel_users(membership), &(&1.nick == "ak"))

    Chat.broadcast_presence_diff(connection, "#elixir", %{action: "part", nick: "ak"})

    refute Enum.any?(Chat.list_channel_users(membership), &(&1.nick == "ak"))
  end

  test "broadcasts inbound channel messages as normalized buffer events" do
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Chat.create_connection(user, %{
        "name" => "local",
        "host" => "127.0.0.1",
        "port" => 6667,
        "use_tls" => false,
        "nickname" => "mira"
      })

    {:ok, membership} = Chat.join_channel(user, connection, "#elixir")

    Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{user.id}")

    Chat.record_inbound_message(connection, "#elixir", "akash", "hello", "message", %{
      hostmask: "akash!user@example.test",
      sender_role: "voice"
    })

    assert_receive {:buffer_message,
                    %{
                      type: "buffer:message",
                      version: 1,
                      event_id: "message:" <> _,
                      buffer_id: buffer_id,
                      server_connection_id: connection_id,
                      channel_membership_id: membership_id,
                      channel: "#elixir",
                      hostmask: "akash!user@example.test",
                      sender_role: "voice",
                      body: "hello"
                    }}

    assert buffer_id == "channel:#{membership.id}"
    assert connection_id == connection.id
    assert membership_id == membership.id

    assert [%Message{hostmask: "akash!user@example.test", sender_role: "voice"}] =
             MessageHistory.list_messages(user, membership.id)
  end
end
