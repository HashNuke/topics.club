defmodule Ircpipe.Chat.CommandMessagesTest do
  use Ircpipe.DataCase, async: true

  alias Ircpipe.AccountsFixtures
  alias Ircpipe.Chat
  alias Ircpipe.Chat.{CommandMessages, Connections, Message}
  alias Ircpipe.Repo

  setup do
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(user, %{
        "name" => "command messages",
        "host" => "irc.example.test",
        "port" => 6697,
        "use_tls" => true,
        "nickname" => "mira"
      })

    {:ok, membership} = Chat.join_channel(user, connection, "#elixir")
    Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{user.id}")

    %{connection: connection, membership: membership, user: user}
  end

  test "records server and channel commands in the requested buffer", context do
    assert {:ok, server_message} =
             CommandMessages.record(
               context.connection,
               "server:#{context.connection.id}",
               "LIST",
               %{command_id: "list-1", command_status: "sent"}
             )

    assert %Message{
             kind: "command",
             nick: "mira",
             body: "LIST",
             channel_membership_id: nil,
             metadata: %{"command_id" => "list-1", "command_status" => "sent"}
           } = server_message

    assert_receive {:buffer_system,
                    %{id: server_message_id, buffer_id: server_buffer_id, body: "LIST"}}

    assert server_message_id == server_message.id
    assert server_buffer_id == "server:#{context.connection.id}"

    assert {:ok, channel_message} =
             CommandMessages.record(
               context.connection,
               "channel:#{context.membership.id}",
               "WHO #elixir",
               %{command_id: "who-1"}
             )

    assert channel_message.channel_membership_id == context.membership.id

    assert_receive {:buffer_system,
                    %{id: channel_message_id, buffer_id: channel_buffer_id, body: "WHO #elixir"}}

    assert channel_message_id == channel_message.id
    assert channel_buffer_id == "channel:#{context.membership.id}"
  end

  test "updates command metadata without discarding existing values", context do
    assert {:ok, message} =
             CommandMessages.record(
               context.connection,
               "server:#{context.connection.id}",
               "WHOIS mira",
               %{command_id: "whois-1", command_status: "sent"}
             )

    assert_receive {:buffer_system, %{id: message_id}}
    assert message_id == message.id

    assert {:ok, updated} =
             CommandMessages.update(message, %{command_status: "completed", elapsed_ms: 12})

    assert updated.metadata == %{
             "command_id" => "whois-1",
             "command_status" => "completed",
             "elapsed_ms" => 12
           }

    assert Repo.get!(Message, message.id).metadata == updated.metadata
    assert_receive {:buffer_system, %{id: updated_message_id}}
    assert updated_message_id == updated.id
  end

  test "rejects buffers owned by another connection", context do
    other_user = AccountsFixtures.user_fixture()

    {:ok, other_connection} =
      Connections.create(other_user, %{
        "name" => "foreign commands",
        "host" => "irc.other.test",
        "port" => 6697,
        "use_tls" => true,
        "nickname" => "other"
      })

    {:ok, other_membership} = Chat.join_channel(other_user, other_connection, "#private")

    assert_raise Ecto.NoResultsError, fn ->
      CommandMessages.record(
        context.connection,
        "channel:#{other_membership.id}",
        "WHO #private",
        %{command_id: "foreign-channel"}
      )
    end

    assert_raise Ecto.NoResultsError, fn ->
      CommandMessages.record(
        context.connection,
        "server:#{other_connection.id}",
        "LIST",
        %{command_id: "foreign-server"}
      )
    end
  end

  test "rejects an outer transaction before recording or publishing", context do
    buffer_id = "server:#{context.connection.id}"

    assert {:ok, :committed} =
             Repo.transaction(fn ->
               assert_raise ArgumentError, ~r/existing transaction/, fn ->
                 CommandMessages.record(context.connection, buffer_id, "OPER secret", %{
                   command_id: "outer-record"
                 })
               end

               :committed
             end)

    refute Repo.get_by(Message, body: "OPER secret")
    refute_receive {:buffer_system, %{body: "OPER secret"}}
  end

  test "rejects an outer transaction before updating or publishing", context do
    assert {:ok, message} =
             CommandMessages.record(
               context.connection,
               "server:#{context.connection.id}",
               "LIST",
               %{command_id: "outer-update", command_status: "sent"}
             )

    assert_receive {:buffer_system, %{id: message_id}}
    assert message_id == message.id

    assert {:ok, :committed} =
             Repo.transaction(fn ->
               assert_raise ArgumentError, ~r/existing transaction/, fn ->
                 CommandMessages.update(message, %{command_status: "completed"})
               end

               :committed
             end)

    assert Repo.get!(Message, message.id).metadata["command_status"] == "sent"
    refute_receive {:buffer_system, %{id: ^message_id}}
  end
end
