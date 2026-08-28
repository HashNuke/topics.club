defmodule TopicsClubWeb.UserChannel.BufferResolverTest do
  use TopicsClub.DataCase, async: true

  alias TopicsClub.AccountsFixtures
  alias TopicsClub.Chat
  alias TopicsClub.Chat.ChannelPartLifecycle
  alias TopicsClub.Chat.Connections
  alias TopicsClub.Chat.DirectMessageLifecycle
  alias TopicsClubWeb.UserChannel.BufferResolver

  setup do
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(user, %{
        "name" => "Libera",
        "host" => "irc.example.test",
        "port" => 6697,
        "use_tls" => true,
        "nickname" => "mira"
      })

    {:ok, membership} = Chat.join_channel(user, connection, "#elixir")
    {:ok, thread} = DirectMessageLifecycle.open(user, connection, "akash")

    %{user: user, connection: connection, membership: membership, thread: thread}
  end

  test "resolves owned channel, server, and direct-message buffers", context do
    assert {:ok, membership} =
             BufferResolver.membership(context.user, Integer.to_string(context.membership.id))

    assert membership.id == context.membership.id

    assert {:ok, connection} =
             BufferResolver.connection(context.user, "server:#{context.connection.id}")

    assert connection.id == context.connection.id

    assert {:ok, channel_connection} =
             BufferResolver.connection(context.user, "channel:#{context.membership.id}")

    assert channel_connection.id == context.connection.id

    assert {:ok, direct_connection} =
             BufferResolver.connection(context.user, "direct:#{context.thread.id}")

    assert direct_connection.id == context.connection.id
  end

  test "rejects missing, malformed, and inactive buffers", context do
    assert {:error, :invalid_buffer} = BufferResolver.membership(context.user, "missing")
    assert {:error, :invalid_server} = BufferResolver.connection(context.user, "server:missing")

    assert {:error, :invalid_direct_message} =
             BufferResolver.direct_message_thread(context.user, "missing")

    assert {:error, :invalid_direct_message} =
             BufferResolver.connection(context.user, "direct:missing")

    assert {:error, :invalid_buffer} = BufferResolver.connection(context.user, "bogus:1")

    {:ok, _left} =
      ChannelPartLifecycle.confirm(context.connection, context.membership.channel)

    assert {:error, :invalid_buffer} =
             BufferResolver.membership(context.user, Integer.to_string(context.membership.id))
  end

  test "resolves direct-message threads only for their owner", context do
    assert {:ok, thread} =
             BufferResolver.direct_message_thread(
               context.user,
               Integer.to_string(context.thread.id)
             )

    assert thread.id == context.thread.id

    other_user = AccountsFixtures.user_fixture()

    assert {:error, :invalid_server} =
             BufferResolver.connection(other_user, "server:#{context.connection.id}")

    assert {:error, :invalid_buffer} =
             BufferResolver.membership(other_user, Integer.to_string(context.membership.id))

    assert {:error, :invalid_buffer} =
             BufferResolver.connection(other_user, "channel:#{context.membership.id}")

    assert {:error, :invalid_direct_message} =
             BufferResolver.direct_message_thread(
               other_user,
               Integer.to_string(context.thread.id)
             )
  end

  test "resolves part-command targets from the current buffer or explicit channel", context do
    assert {:ok, current_membership} =
             BufferResolver.part_membership(
               context.user,
               "channel:#{context.membership.id}",
               []
             )

    assert current_membership.id == context.membership.id

    assert {:ok, explicit_membership} =
             BufferResolver.part_membership(
               context.user,
               "server:#{context.connection.id}",
               ["#elixir"]
             )

    assert explicit_membership.id == context.membership.id

    assert {:error, :invalid_command_args} =
             BufferResolver.part_membership(
               context.user,
               "server:#{context.connection.id}",
               ["#one", "#two"]
             )
  end
end
