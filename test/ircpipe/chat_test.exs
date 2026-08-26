defmodule Ircpipe.ChatTest do
  use Ircpipe.DataCase, async: true

  alias Ircpipe.AccountsFixtures
  alias Ircpipe.Chat
  alias Ircpipe.Chat.Connections

  alias Ircpipe.Chat.{
    ChannelMembership,
    ChannelUser,
    MembershipReconciler,
    Message,
    MessageHistory,
    Presence,
    Retention
  }

  alias Ircpipe.Repo

  test "scopes server connections to their owner" do
    user = AccountsFixtures.user_fixture()
    other_user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(user, %{
        "name" => "local",
        "host" => "127.0.0.1",
        "port" => 6667,
        "use_tls" => false,
        "nickname" => "mira"
      })

    assert [owned] = Connections.list(user)
    assert owned.id == connection.id
    assert [] = Connections.list(other_user)
    assert_raise Ecto.NoResultsError, fn -> Connections.get!(other_user, connection.id) end
  end

  test "does not join channels on another user's server connection" do
    user = AccountsFixtures.user_fixture()
    other_user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(other_user, %{
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
      Connections.create(user, %{
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
      Connections.create(user, %{
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
      Connections.create(user, %{
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

    observed_at = DateTime.utc_now(:second)

    for {membership, attrs} <- [
          {first, %{nick: "first-only", role: "op", status: "online", hostmask: "first!host"}},
          {first, %{nick: "shared", role: "op", status: "online", hostmask: "first!host"}},
          {second,
           %{nick: "second-only", role: "voice", status: "away", hostmask: "second!host"}},
          {second, %{nick: "shared", role: "voice", status: "away", hostmask: "second!host"}}
        ] do
      %ChannelUser{channel_membership_id: membership.id}
      |> ChannelUser.changeset(Map.put(attrs, :last_observed_at, observed_at))
      |> Repo.insert!()
    end

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
    assert {:ok, [_loser]} = MembershipReconciler.reconcile(connection, :rfc1459)

    assert_receive {:buffer_left,
                    %{
                      type: "buffer:left",
                      version: 1,
                      buffer_id: "channel:" <> _,
                      server_connection_id: connection_id,
                      channel_membership_id: loser_id,
                      channel: loser_channel
                    } = event}

    refute Map.has_key?(event, :user_id)
    assert connection_id == connection.id
    assert loser_id in [first.id, second.id]
    assert loser_channel in [first.channel, second.channel]
    membership = Chat.get_channel_membership(connection, "#" <> "{OPS}", :rfc1459)
    assert membership.id in [first.id, second.id]

    assert Enum.map(MessageHistory.list_messages(user, membership.id), & &1.body) == [
             "first history",
             "second history"
           ]

    assert [
             %{nick: "first-only", role: "op", status: "online", hostmask: "first!host"},
             %{nick: "second-only", role: "voice", status: "away", hostmask: "second!host"},
             %{nick: "shared", role: "voice", status: "away", hostmask: "second!host"}
           ] = Presence.list_users(membership)

    memberships = Repo.all(ChannelMembership)
    assert Enum.count(memberships, &(&1.server_connection_id == connection.id)) == 1
  end

  test "does not reconcile bracket-equivalent memberships before casemapping is trusted" do
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(user, %{
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
    assert [%{channel_memberships: memberships}] = Connections.list(user)
    assert Enum.count(memberships) == 2

    {:ok, ascii_connection} = Chat.update_connection_casemapping(connection, :ascii)
    assert {:ok, []} = MembershipReconciler.reconcile(ascii_connection, :ascii)
    assert [%{channel_memberships: memberships}] = Connections.list(user)
    assert Enum.count(memberships) == 2
  end

  test "scopes channel memberships and buffer history to their owner" do
    user = AccountsFixtures.user_fixture()
    other_user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(user, %{
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
    {:ok, user} = Retention.update_days(user, 1)

    {:ok, connection} =
      Connections.create(user, %{
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
      Connections.create(user, %{
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

    assert Connections.get!(user, connection.id).unread_count == 1
  end

  test "marks server buffers read" do
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(user, %{
        "name" => "local",
        "host" => "127.0.0.1",
        "port" => 6667,
        "use_tls" => false,
        "nickname" => "mira"
      })

    Chat.record_server_message(connection, "Connected")
    Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{user.id}")

    assert :ok = Chat.mark_read(user, Connections.get!(user, connection.id))

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

    reloaded = Connections.get!(user, connection.id)
    assert reloaded.unread_count == 0
    assert reloaded.mention_count == 0
  end

  test "broadcasts server errors as buffer error events" do
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(user, %{
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
      Connections.create(user, %{
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
      Connections.create(user, %{
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

  test "broadcasts inbound channel messages as normalized buffer events" do
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(user, %{
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
