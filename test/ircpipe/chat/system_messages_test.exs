defmodule Ircpipe.Chat.SystemMessagesTest do
  use Ircpipe.DataCase, async: true

  alias Ircpipe.AccountsFixtures
  alias Ircpipe.Chat

  alias Ircpipe.Chat.{
    Connections,
    Message,
    MessageHistory,
    Presence,
    SystemMessages
  }

  alias Ircpipe.Repo

  setup do
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(user, %{
        "name" => "system messages",
        "host" => "irc.example.test",
        "port" => 6697,
        "use_tls" => true,
        "nickname" => "mira"
      })

    {:ok, elixir} = Chat.join_channel(user, connection, "#elixir")
    {:ok, phoenix} = Chat.join_channel(user, connection, "#phoenix")
    Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{user.id}")

    %{connection: connection, elixir: elixir, phoenix: phoenix, user: user}
  end

  test "records and publishes a channel system message", context do
    assert {:ok, message} =
             SystemMessages.record(
               context.connection,
               "#ELIXIR",
               "join",
               "akash",
               "akash joined #elixir.",
               %{account: "akash_irc"},
               :ascii
             )

    assert %Message{
             kind: "join",
             nick: "akash",
             body: "akash joined #elixir.",
             mentioned: false,
             metadata: %{"account" => "akash_irc"}
           } = message

    assert message.channel_membership_id == context.elixir.id

    assert_receive {:buffer_system,
                    %{
                      id: message_id,
                      buffer_id: buffer_id,
                      body: "akash joined #elixir."
                    }}

    assert message_id == message.id
    assert buffer_id == "channel:#{context.elixir.id}"
  end

  test "records only in joined channels where a nick is present", context do
    Presence.sync(context.connection, "#elixir", [%{nick: "Akash", prefixes: []}])
    Presence.sync(context.connection, "#phoenix", [%{nick: "Other", prefixes: []}])

    assert :ok =
             SystemMessages.record_for_present_nick(
               context.connection,
               "nick",
               "akash",
               "Akash_",
               fn membership -> "Akash is now Akash_ in #{membership.channel}." end
             )

    assert [%{nick: "Akash_", body: "Akash is now Akash_ in #elixir."}] =
             MessageHistory.list_buffer_messages(
               context.user,
               "channel:#{context.elixir.id}"
             )

    assert [] =
             MessageHistory.list_buffer_messages(
               context.user,
               "channel:#{context.phoenix.id}"
             )
  end

  test "rejects an outer transaction before recording or publishing", context do
    assert {:ok, :committed} =
             Repo.transaction(fn ->
               assert_raise ArgumentError, ~r/existing transaction/, fn ->
                 SystemMessages.record(
                   context.connection,
                   "#elixir",
                   "error",
                   nil,
                   "Cannot join channel"
                 )
               end

               :committed
             end)

    refute Repo.get_by(Message, body: "Cannot join channel")
    refute_receive {:buffer_system, %{body: "Cannot join channel"}}
  end

  test "does not record after deletion is marked", context do
    context.connection
    |> Ecto.Changeset.change(deleting: true)
    |> Repo.update!()

    assert {:error, :connection_deleting} =
             SystemMessages.record(
               context.connection,
               "#elixir",
               "join",
               "akash",
               "akash joined too late"
             )

    refute Repo.get_by(Message, body: "akash joined too late")
    refute_received {:buffer_system, _event}
  end
end
