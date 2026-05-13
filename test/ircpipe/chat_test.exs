defmodule Ircpipe.ChatTest do
  use Ircpipe.DataCase, async: true

  alias Ircpipe.AccountsFixtures
  alias Ircpipe.Chat
  alias Ircpipe.Chat.Message

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
             Chat.list_buffer_messages(user, "channel:#{membership.id}")

    assert_raise Ecto.NoResultsError, fn -> Chat.get_membership!(other_user, membership.id) end

    assert_raise Ecto.NoResultsError, fn ->
      Chat.get_membership_by_channel!(other_user, connection, "#elixir")
    end

    assert_raise Ecto.NoResultsError, fn ->
      Chat.list_buffer_messages(other_user, "channel:#{membership.id}")
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
    assert [%Message{body: "new"}] = Chat.list_messages(user, membership.id)
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
             Chat.list_buffer_messages(user, "server:#{connection.id}")
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
             Chat.list_messages(user, membership.id)
  end
end
