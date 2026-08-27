defmodule Ircpipe.Chat.ChannelPartLifecycleTest do
  use Ircpipe.DataCase, async: true

  alias Ircpipe.AccountsFixtures
  alias Ircpipe.Chat
  alias Ircpipe.Chat.{ChannelPartLifecycle, Connections, Presence}

  test "owns confirmed channel departures without Chat compatibility APIs" do
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(user, %{
        "name" => "channel-part-owner",
        "host" => "irc.channel-part-owner.test",
        "nickname" => "mira"
      })

    {:ok, membership} = Chat.join_channel(user, connection, "#elixir")

    assert :ok =
             Presence.sync(
               connection,
               membership.channel,
               [%{nick: "akash", prefixes: ["@"]}],
               :rfc1459
             )

    assert [%{nick: "akash", role: "op"}] = Presence.list_users(membership)
    Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{user.id}")

    assert {:ok, departed} = ChannelPartLifecycle.confirm(connection, membership.channel)
    assert departed.status == "left"
    refute departed.auto_join
    assert departed.left_at
    assert Presence.list_users(departed) == []

    assert_receive {:buffer_left,
                    %{
                      type: "buffer:left",
                      buffer_id: buffer_id,
                      server_connection_id: connection_id,
                      channel_membership_id: membership_id
                    }}

    assert buffer_id == "channel:#{membership.id}"
    assert connection_id == connection.id
    assert membership_id == membership.id

    assert {:ok, duplicate} = ChannelPartLifecycle.confirm(connection, membership.channel)
    assert duplicate.left_at == departed.left_at
    refute_receive {:buffer_left, _event}

    assert {:module, Chat} = Code.ensure_loaded(Chat)
    refute function_exported?(Chat, :confirm_channel_left, 2)
    refute function_exported?(Chat, :confirm_channel_left, 3)
    refute function_exported?(Chat, :reject_channel_part, 3)
    refute function_exported?(Chat, :reject_channel_part, 4)
    refute function_exported?(Chat, :leave_channel, 2)
  end

  test "records a rejected PART against the casemapped joined membership" do
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(user, %{
        "name" => "channel-part-rejection",
        "host" => "irc.channel-part-rejection.test",
        "nickname" => "mira"
      })

    {:ok, membership} = Chat.join_channel(user, connection, "#[Ops]")
    Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{user.id}")

    assert {:ok, rejected} =
             ChannelPartLifecycle.reject(
               connection,
               "#" <> "{OPS}",
               :not_on_channel,
               :rfc1459
             )

    assert rejected.id == membership.id
    assert rejected.status == "joined"
    assert rejected.last_error == ":not_on_channel"
    refute_receive {:buffer_left, _event}
  end
end
