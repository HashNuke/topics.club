defmodule Ircpipe.Chat.PresenceTest do
  use Ircpipe.DataCase, async: true

  alias Ircpipe.AccountsFixtures
  alias Ircpipe.Chat
  alias Ircpipe.Chat.Connections
  alias Ircpipe.Chat.Presence

  setup do
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(user, %{
        "name" => "presence",
        "host" => "irc.presence.test",
        "nickname" => "mira"
      })

    {:ok, membership} = Chat.join_channel(user, connection, "#elixir")
    Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{user.id}")

    %{connection: connection, membership: membership, user: user}
  end

  test "sync replaces stored users and broadcasts the normalized snapshot", %{
    connection: connection,
    membership: membership
  } do
    assert :ok =
             Presence.sync(connection, "#elixir", [
               %{nick: "mira", prefixes: ["@"], raw_source: "mira!user@example.test"},
               %{nick: "akash", prefixes: []}
             ])

    assert_receive {:presence_sync,
                    %{
                      server_connection_id: connection_id,
                      channel_membership_id: membership_id,
                      users: users
                    }}

    assert connection_id == connection.id
    assert membership_id == membership.id
    assert Enum.map(users, & &1.nick) == ["mira", "akash"]

    assert [
             %{nick: "akash", role: "user", status: "online"},
             %{
               nick: "mira",
               role: "op",
               status: "online",
               hostmask: "mira!user@example.test"
             }
           ] = Presence.list_users(membership)

    assert :ok = Presence.sync(connection, "#elixir", [%{nick: "mira", prefixes: []}])
    assert [%{nick: "mira", role: "user"}] = Presence.list_users(membership)
  end

  test "diffs persist joins, away state, roles, nicknames, parts, and quits", %{
    connection: connection,
    membership: membership,
    user: user
  } do
    {:ok, other_membership} = Chat.join_channel(user, connection, "#phoenix")

    Presence.sync(connection, "#elixir", [%{nick: "akash", prefixes: []}])
    Presence.sync(connection, "#phoenix", [%{nick: "akash", prefixes: []}])

    assert :ok =
             Presence.diff(connection, nil, %{action: "away", nick: "akash", status: "away"})

    assert Enum.all?([membership, other_membership], fn membership ->
             [%{nick: "akash", status: "away"}] = Presence.list_users(membership)
           end)

    assert :ok =
             Presence.diff(connection, "#elixir", %{
               action: "role",
               nick: "akash",
               role: "voice"
             })

    assert :ok =
             Presence.diff(connection, "#elixir", %{
               action: "nick",
               old_nick: "akash",
               new_nick: "ak"
             })

    assert [%{nick: "ak", role: "voice"}] = Presence.list_users(membership)

    assert :ok =
             Presence.diff(connection, "#elixir", %{
               action: "join",
               user: %{nick: "new", role: "user", status: "online"}
             })

    assert Enum.any?(Presence.list_users(membership), &(&1.nick == "new"))
    assert :ok = Presence.diff(connection, "#elixir", %{action: "part", nick: "ak"})
    refute Enum.any?(Presence.list_users(membership), &(&1.nick == "ak"))

    assert :ok = Presence.diff(connection, nil, %{action: "quit", nick: "akash"})
    assert Presence.list_users(other_membership) == []
  end

  test "syncing an unknown channel is a no-op", %{connection: connection} do
    assert :ok = Presence.sync(connection, "#missing", [%{nick: "akash", prefixes: []}])
    refute_receive {:presence_sync, _event}
  end
end
