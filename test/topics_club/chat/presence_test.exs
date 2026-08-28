defmodule TopicsClub.Chat.PresenceTest do
  use TopicsClub.DataCase, async: true

  alias TopicsClub.AccountsFixtures
  alias TopicsClub.Chat
  alias TopicsClub.Chat.Connections
  alias TopicsClub.Chat.Presence

  setup do
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(user, %{
        "name" => "presence",
        "host" => "irc.presence.test",
        "nickname" => "mira"
      })

    {:ok, membership} = Chat.join_channel(user, connection, "#elixir")
    Phoenix.PubSub.subscribe(TopicsClub.PubSub, "user:#{user.id}")

    %{connection: connection, membership: membership, user: user}
  end

  test "sync replaces stored users and broadcasts the normalized snapshot", %{
    connection: connection,
    membership: membership
  } do
    assert :ok =
             Presence.sync(
               connection,
               "#elixir",
               [
                 %{nick: "mira", prefixes: ["@"], raw_source: "mira!user@example.test"},
                 %{nick: "akash", prefixes: []}
               ],
               :rfc1459
             )

    assert_receive {:presence_sync,
                    %{
                      server_connection_id: connection_id,
                      channel_membership_id: membership_id,
                      users: users
                    }}

    assert connection_id == connection.id
    assert membership_id == membership.id

    assert Enum.map(users, &Map.take(&1, [:nick, :nick_key])) == [
             %{nick: "mira", nick_key: "mira"},
             %{nick: "akash", nick_key: "akash"}
           ]

    assert [
             %{nick: "akash", role: "user", status: "online"},
             %{
               nick: "mira",
               role: "op",
               status: "online",
               hostmask: "mira!user@example.test"
             }
           ] = Presence.list_users(membership)

    assert :ok =
             Presence.sync(connection, "#elixir", [%{nick: "mira", prefixes: []}], :rfc1459)

    assert [%{nick: "mira", role: "user"}] = Presence.list_users(membership)
  end

  test "canonical nick keys deduplicate snapshots and target equivalent diff nicknames", %{
    connection: connection,
    membership: membership
  } do
    assert :ok =
             Presence.sync(
               connection,
               "#elixir",
               [
                 %{nick: "[Mira]", prefixes: []},
                 %{nick: "{mira}", prefixes: ["@"]}
               ],
               :rfc1459
             )

    assert [%{nick: "{mira}", nick_key: "{mira}", role: "op"}] =
             Presence.list_users(membership)

    assert :ok =
             Presence.diff(
               connection,
               "#elixir",
               %{action: "away", nick: "[MIRA]", status: "away"},
               :rfc1459
             )

    assert [%{nick: "{mira}", nick_key: "{mira}", status: "away"}] =
             Presence.list_users(membership)

    assert_receive {:presence_diff,
                    %{diff: %{action: "away", nick: "[MIRA]", nick_key: "{mira}"}}}

    assert :ok =
             Presence.diff(
               connection,
               "#elixir",
               %{action: "nick", old_nick: "[mira]", new_nick: "Other"},
               :rfc1459
             )

    assert [%{nick: "Other", nick_key: "other"}] = Presence.list_users(membership)

    assert_receive {:presence_diff,
                    %{
                      diff: %{
                        action: "nick",
                        old_nick: "[mira]",
                        old_nick_key: "{mira}",
                        new_nick: "Other",
                        new_nick_key: "other"
                      }
                    }}

    assert :ok =
             Presence.diff(
               connection,
               "#elixir",
               %{action: "part", nick: "OTHER"},
               :rfc1459
             )

    assert Presence.list_users(membership) == []
  end

  test "diffs persist joins, away state, roles, nicknames, parts, and quits", %{
    connection: connection,
    membership: membership,
    user: user
  } do
    {:ok, other_membership} = Chat.join_channel(user, connection, "#phoenix")

    Presence.sync(connection, "#elixir", [%{nick: "akash", prefixes: []}], :rfc1459)
    Presence.sync(connection, "#phoenix", [%{nick: "akash", prefixes: []}], :rfc1459)

    assert :ok =
             Presence.diff(
               connection,
               nil,
               %{action: "away", nick: "akash", status: "away"},
               :rfc1459
             )

    assert Enum.all?([membership, other_membership], fn membership ->
             [%{nick: "akash", status: "away"}] = Presence.list_users(membership)
           end)

    assert :ok =
             Presence.diff(
               connection,
               "#elixir",
               %{action: "role", nick: "akash", role: "voice"},
               :rfc1459
             )

    assert :ok =
             Presence.diff(
               connection,
               "#elixir",
               %{action: "nick", old_nick: "akash", new_nick: "ak"},
               :rfc1459
             )

    assert [%{nick: "ak", role: "voice"}] = Presence.list_users(membership)

    assert :ok =
             Presence.diff(
               connection,
               "#elixir",
               %{action: "join", user: %{nick: "new", role: "user", status: "online"}},
               :rfc1459
             )

    assert Enum.any?(Presence.list_users(membership), &(&1.nick == "new"))

    assert :ok =
             Presence.diff(connection, "#elixir", %{action: "part", nick: "ak"}, :rfc1459)

    refute Enum.any?(Presence.list_users(membership), &(&1.nick == "ak"))

    assert :ok =
             Presence.diff(connection, nil, %{action: "quit", nick: "akash"}, :rfc1459)

    assert Presence.list_users(other_membership) == []
  end

  test "syncing an unknown channel is a no-op", %{connection: connection} do
    assert :ok =
             Presence.sync(connection, "#missing", [%{nick: "akash", prefixes: []}], :rfc1459)

    refute_receive {:presence_sync, _event}
  end

  test "drops snapshots and diffs after the connection is marked for deletion", %{
    connection: connection,
    membership: membership
  } do
    connection
    |> Ecto.Changeset.change(deleting: true)
    |> TopicsClub.Repo.update!()

    assert {:error, :connection_deleting} =
             Presence.sync(connection, "#elixir", [%{nick: "akash", prefixes: []}], :rfc1459)

    assert {:error, :connection_deleting} =
             Presence.diff(
               connection,
               "#elixir",
               %{action: "join", user: %{nick: "late", role: "user", status: "online"}},
               :rfc1459
             )

    assert Presence.list_users(membership) == []
    refute_received {:presence_sync, _event}
    refute_received {:presence_diff, _event}
  end

  test "rejects an outer transaction before mutation or publication", %{
    connection: connection,
    membership: membership
  } do
    assert {:ok, :committed} =
             TopicsClub.Repo.transaction(fn ->
               assert_raise ArgumentError,
                            ~r/cannot mutate presence inside an existing transaction/,
                            fn ->
                              Presence.sync(
                                connection,
                                "#elixir",
                                [%{nick: "akash", prefixes: []}],
                                :rfc1459
                              )
                            end

               assert_raise ArgumentError,
                            ~r/cannot mutate presence inside an existing transaction/,
                            fn ->
                              Presence.diff(
                                connection,
                                "#elixir",
                                %{
                                  action: "join",
                                  user: %{nick: "late", role: "user", status: "online"}
                                },
                                :rfc1459
                              )
                            end

               :committed
             end)

    assert Presence.list_users(membership) == []
    refute_received {:presence_sync, _event}
    refute_received {:presence_diff, _event}
  end
end
