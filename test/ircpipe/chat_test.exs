defmodule Ircpipe.ChatTest do
  use Ircpipe.DataCase, async: true

  alias Ircpipe.AccountsFixtures
  alias Ircpipe.Chat
  alias Ircpipe.Chat.Connections
  alias Ircpipe.Chat.MessageIngestion
  alias Ircpipe.Chat.ReadState

  alias Ircpipe.Chat.{
    ChannelJoinRequest,
    ChannelMembership,
    ChannelPartLifecycle,
    ChannelUser,
    ConnectionCasemapping,
    MembershipLookup,
    MembershipReconciler,
    Message,
    MessageHistory,
    Presence,
    Retention,
    SystemMessages
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

    {:ok, pending} = ChannelJoinRequest.request(user, connection, "#elixir")
    assert pending.status == "pending"
    assert pending.auto_join

    {:ok, joined} = Chat.confirm_channel_join(connection, "#elixir")
    assert joined.id == pending.id
    assert joined.status == "joined"
    assert joined.joined_at

    {:ok, duplicate_confirmation} = Chat.confirm_channel_join(connection, "#elixir")
    assert duplicate_confirmation.joined_at == joined.joined_at

    MessageIngestion.record_channel(connection, "#elixir", "akash", "history survives")

    {:ok, left} = ChannelPartLifecycle.confirm(connection, "#elixir")
    assert left.id == pending.id
    assert left.status == "left"
    refute left.auto_join
    assert left.left_at
    assert [%Message{body: "history survives"}] = MessageHistory.list_messages(user, left.id)

    {:ok, duplicate_left} = ChannelPartLifecycle.confirm(connection, "#elixir")
    assert duplicate_left.left_at == left.left_at

    Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{user.id}")
    {:ok, rejoining} = ChannelJoinRequest.request(user, connection, "#elixir")
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

    {:ok, ascii_pending} = ChannelJoinRequest.request(user, connection, "#Pipe", :ascii)
    {:ok, ascii_joined} = Chat.confirm_channel_join(connection, "#pipe", :ascii)
    assert ascii_joined.id == ascii_pending.id

    {:ok, rfc_pending} = ChannelJoinRequest.request(user, connection, "#[Ops]", :rfc1459)
    {:ok, rfc_joined} = Chat.confirm_channel_join(connection, "#" <> "{ops}", :rfc1459)
    assert rfc_joined.id == rfc_pending.id

    assert MembershipLookup.find_by_channel(connection, "#PIPE", :ascii).id == ascii_pending.id

    assert MembershipLookup.find_by_channel(connection, "#" <> "{OPS}", :rfc1459).id ==
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
      attrs =
        attrs
        |> Map.put(:nick_key, Ircpipe.Irc.Identifier.key(attrs.nick, :rfc1459))
        |> Map.put(:last_observed_at, observed_at)

      %ChannelUser{channel_membership_id: membership.id}
      |> ChannelUser.changeset(attrs)
      |> Repo.insert!()
    end

    MessageIngestion.record_channel(
      connection,
      "#[Ops]",
      "mira",
      "first history",
      "message",
      %{},
      :ascii
    )

    MessageIngestion.record_channel(
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
    membership = MembershipLookup.find_by_channel(connection, "#" <> "{OPS}", :rfc1459)
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

    {:ok, ascii_connection} = ConnectionCasemapping.update(connection, :ascii)
    assert {:ok, []} = MembershipReconciler.reconcile(ascii_connection, :ascii)
    assert [%{channel_memberships: memberships}] = Connections.list(user)
    assert Enum.count(memberships) == 2
  end

  test "changing casemapping atomically rekeys and deduplicates stored presence" do
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(user, %{
        "name" => "presence-casemapping",
        "host" => "irc.presence-casemapping.test",
        "nickname" => "mira"
      })

    {:ok, connection} = ConnectionCasemapping.update(connection, :ascii)
    {:ok, membership} = Chat.join_channel(user, connection, "#room")

    :ok =
      Presence.sync(
        connection,
        "#room",
        [%{nick: "[Mira]", prefixes: []}, %{nick: "{mira}", prefixes: ["@"]}],
        :ascii
      )

    assert Presence.list_users(membership) |> Enum.map(& &1.nick_key) |> Enum.sort() ==
             ["[mira]", "{mira}"]

    assert {:ok, rfc_connection} = ConnectionCasemapping.update(connection, :rfc1459)
    assert rfc_connection.casemapping == "rfc1459"

    assert [%{nick: "{mira}", nick_key: "{mira}", role: "op"}] =
             Presence.list_users(membership)

    assert :ok =
             Presence.diff(
               rfc_connection,
               "#room",
               %{action: "away", nick: "[MIRA]", status: "away"},
               :rfc1459
             )

    assert [%{nick_key: "{mira}", status: "away"}] = Presence.list_users(membership)
  end

  test "changing from RFC1459 to strict RFC1459 rekeys tilde nicknames" do
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(user, %{
        "name" => "strict-presence-casemapping",
        "host" => "irc.strict-presence-casemapping.test",
        "nickname" => "mira"
      })

    {:ok, connection} = ConnectionCasemapping.update(connection, :rfc1459)
    {:ok, membership} = Chat.join_channel(user, connection, "#room")
    :ok = Presence.sync(connection, "#room", [%{nick: "mi~ra", prefixes: []}], :rfc1459)

    assert [%{nick: "mi~ra", nick_key: "mi^ra"}] = Presence.list_users(membership)

    assert {:ok, strict_connection} =
             ConnectionCasemapping.update(connection, :strict_rfc1459)

    assert [%{nick: "mi~ra", nick_key: "mi~ra"}] = Presence.list_users(membership)

    assert :ok =
             Presence.diff(
               strict_connection,
               "#room",
               %{action: "join", user: %{nick: "mi^ra", role: "user", status: "online"}},
               :strict_rfc1459
             )

    assert Presence.list_users(membership) |> Enum.map(& &1.nick_key) |> Enum.sort() ==
             ["mi^ra", "mi~ra"]
  end

  test "membership lifecycle rejects a connection marked for deletion" do
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(user, %{
        "name" => "deleting-memberships",
        "host" => "irc.deleting-memberships.test",
        "nickname" => "mira"
      })

    {:ok, pending_join} = ChannelJoinRequest.request(user, connection, "#confirm")
    {:ok, pending_rejection} = ChannelJoinRequest.request(user, connection, "#reject")
    {:ok, joined_left} = Chat.join_channel(user, connection, "#left")
    {:ok, joined_part} = Chat.join_channel(user, connection, "#part")

    connection
    |> Ecto.Changeset.change(deleting: true)
    |> Repo.update!()

    Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{user.id}")

    assert {:error, :connection_deleting} =
             ConnectionCasemapping.update(connection, :rfc1459)

    assert {:error, :connection_deleting} =
             ChannelJoinRequest.request(user, connection, "#after-mark")

    assert {:error, :connection_deleting} =
             Chat.confirm_channel_join(connection, pending_join.channel)

    assert {:error, :connection_deleting} =
             Chat.reject_channel_join(connection, pending_rejection.channel, "too late")

    assert {:error, :connection_deleting} =
             ChannelPartLifecycle.confirm(connection, joined_left.channel)

    assert {:error, :connection_deleting} =
             ChannelPartLifecycle.reject(connection, joined_part.channel, "too late")

    assert {:error, :connection_deleting} = MembershipReconciler.reconcile(connection, :rfc1459)

    assert Repo.get!(ChannelMembership, pending_join.id).status == "pending"
    assert Repo.get!(ChannelMembership, pending_rejection.id).status == "pending"
    assert Repo.get!(ChannelMembership, joined_left.id).status == "joined"
    assert Repo.get!(ChannelMembership, joined_part.id).last_error == nil
    refute MembershipLookup.find_by_channel(connection, "#after-mark")
    refute_received {:buffer_joined, _event}
    refute_received {:buffer_left, _event}
  end

  test "membership lifecycle rejects an outer transaction before mutation" do
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(user, %{
        "name" => "outer-memberships",
        "host" => "irc.outer-memberships.test",
        "nickname" => "mira"
      })

    {:ok, pending} = ChannelJoinRequest.request(user, connection, "#pending")
    Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{user.id}")

    assert {:ok, :committed} =
             Repo.transaction(fn ->
               for callback <- [
                     fn -> ConnectionCasemapping.update(connection, :rfc1459) end,
                     fn -> ChannelJoinRequest.request(user, connection, "#new") end,
                     fn -> Chat.confirm_channel_join(connection, pending.channel) end,
                     fn -> Chat.reject_channel_join(connection, pending.channel, "too late") end,
                     fn -> ChannelPartLifecycle.confirm(connection, pending.channel) end,
                     fn ->
                       ChannelPartLifecycle.reject(connection, pending.channel, "too late")
                     end,
                     fn -> MembershipReconciler.reconcile(connection, :rfc1459) end
                   ] do
                 assert_raise ArgumentError, ~r/existing transaction/, callback
               end

               :committed
             end)

    assert Repo.get!(ChannelMembership, pending.id).status == "pending"
    assert Repo.get!(ChannelMembership, pending.id).last_error == nil
    refute MembershipLookup.find_by_channel(connection, "#new")
    assert Repo.get!(Ircpipe.Chat.ServerConnection, connection.id).casemapping == nil
    refute_received {:buffer_joined, _event}
    refute_received {:buffer_left, _event}
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
    MessageIngestion.record_channel(connection, "#elixir", "akash", "scoped")

    assert MembershipLookup.get!(user, membership.id).id == membership.id
    assert MembershipLookup.get_by_channel!(user, connection, "#elixir").id == membership.id

    assert [%Message{body: "scoped"}] =
             MessageHistory.list_buffer_messages(user, "channel:#{membership.id}")

    assert_raise Ecto.NoResultsError, fn -> MembershipLookup.get!(other_user, membership.id) end

    assert_raise Ecto.NoResultsError, fn ->
      MembershipLookup.get_by_channel!(other_user, connection, "#elixir")
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

    MessageIngestion.record_channel(connection, "#elixir", "akash", "new")

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
             MessageIngestion.record_server(connection, "Connected")

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

    MessageIngestion.record_server(connection, "Connected")
    Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{user.id}")

    assert :ok = ReadState.mark(user, Connections.get!(user, connection.id))

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
             MessageIngestion.record_server(connection, "Connection failed", "error")

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
             SystemMessages.record(
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

    MessageIngestion.record_channel(connection, "#elixir", "akash", "hello", "message", %{
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
