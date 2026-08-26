defmodule Ircpipe.Chat.MessageHistoryTest do
  use Ircpipe.DataCase, async: true

  alias Ircpipe.AccountsFixtures
  alias Ircpipe.Chat
  alias Ircpipe.Chat.{Message, MessageHistory}
  alias Ircpipe.Repo

  setup do
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Chat.create_connection(user, %{
        "name" => "history",
        "host" => "irc.example.test",
        "port" => 6697,
        "use_tls" => true,
        "nickname" => "mira"
      })

    {:ok, membership} = Chat.join_channel(user, connection, "#elixir")

    %{user: user, connection: connection, membership: membership}
  end

  test "lists the newest channel messages in chronological order within the limit", context do
    for body <- ["one", "two", "three"] do
      assert {:ok, _message} =
               Chat.record_inbound_message(
                 context.connection,
                 context.membership.channel,
                 "akash",
                 body
               )
    end

    assert ["two", "three"] ==
             context.user
             |> MessageHistory.list_messages(context.membership.id, 2)
             |> Enum.map(& &1.body)
  end

  test "scopes buffer history to its owner", context do
    assert {:ok, _message} =
             Chat.record_inbound_message(
               context.connection,
               context.membership.channel,
               "akash",
               "private history"
             )

    assert [%{body: "private history"}] =
             MessageHistory.list_buffer_messages(
               context.user,
               "channel:#{context.membership.id}"
             )

    other_user = AccountsFixtures.user_fixture()

    assert_raise Ecto.NoResultsError, fn ->
      MessageHistory.list_buffer_messages(
        other_user,
        "channel:#{context.membership.id}"
      )
    end
  end

  test "invalid after cursors return the latest page instead of the oldest page", context do
    [oldest, older, newer, newest] =
      insert_channel_messages(context, [
        {"oldest", ~U[2026-08-26 09:00:00Z]},
        {"older", ~U[2026-08-26 09:01:00Z]},
        {"newer", ~U[2026-08-26 09:02:00Z]},
        {"newest", ~U[2026-08-26 09:03:00Z]}
      ])

    {:ok, other_membership} = Chat.join_channel(context.user, context.connection, "#other")

    other_buffer_cursor =
      insert_message(
        context.user,
        context.connection,
        other_membership,
        "other buffer",
        ~U[2026-08-26 09:01:30Z]
      )

    other_user = AccountsFixtures.user_fixture()

    {:ok, other_connection} =
      Chat.create_connection(other_user, %{
        "name" => "foreign-history",
        "host" => "irc.example.test",
        "port" => 6697,
        "use_tls" => true,
        "nickname" => "other"
      })

    {:ok, other_user_membership} = Chat.join_channel(other_user, other_connection, "#elixir")

    foreign_cursor =
      insert_message(
        other_user,
        other_connection,
        other_user_membership,
        "foreign",
        ~U[2026-08-26 09:01:30Z]
      )

    deleted_cursor =
      insert_message(
        context.user,
        context.connection,
        context.membership,
        "deleted",
        ~U[2026-08-26 09:01:30Z]
      )

    Repo.delete!(deleted_cursor)

    invalid_cursors = [
      "malformed",
      String.duplicate("9", 100),
      9_223_372_036_854_775_808,
      0,
      -1,
      2_000_000_000,
      deleted_cursor.id,
      foreign_cursor.id,
      other_buffer_cursor.id
    ]

    for cursor <- invalid_cursors do
      assert [^newer, ^newest] =
               MessageHistory.list_buffer_messages(
                 context.user,
                 "channel:#{context.membership.id}",
                 after: cursor,
                 limit: 2
               )
    end

    refute oldest.id == older.id
  end

  test "valid cursors use message ids to break equal timestamps", context do
    occurred_at = ~U[2026-08-26 10:00:00Z]

    [first, second, third, fourth] =
      insert_channel_messages(context, [
        {"first", occurred_at},
        {"second", occurred_at},
        {"third", occurred_at},
        {"fourth", occurred_at}
      ])

    assert [^third, ^fourth] =
             MessageHistory.list_buffer_messages(
               context.user,
               "channel:#{context.membership.id}",
               after: second.id
             )

    assert [^second, ^third] =
             MessageHistory.list_buffer_messages(
               context.user,
               "channel:#{context.membership.id}",
               before: fourth.id,
               limit: 2
             )

    refute first.id == second.id
  end

  test "keeps channel, server, and direct-message histories isolated", context do
    assert {:ok, _channel_message} =
             Chat.record_inbound_message(
               context.connection,
               context.membership.channel,
               "akash",
               "channel body"
             )

    assert {:ok, _server_message} = Chat.record_server_message(context.connection, "server body")

    assert {:ok, %{thread: thread}} =
             Chat.record_direct_message(
               context.connection,
               "akash",
               "akash",
               "direct body",
               "message",
               %{direction: "incoming"}
             )

    assert [%{body: "channel body"}] =
             MessageHistory.list_buffer_messages(
               context.user,
               "channel:#{context.membership.id}"
             )

    assert [%{body: "server body"}] =
             MessageHistory.list_buffer_messages(
               context.user,
               "server:#{context.connection.id}"
             )

    assert [%{body: "direct body"}] =
             MessageHistory.list_buffer_messages(context.user, "direct:#{thread.id}")
  end

  test "parses and clamps buffer history limits", context do
    timestamp = ~U[2026-08-26 11:00:00Z]

    rows =
      Enum.map(1..151, fn index ->
        %{
          user_id: context.user.id,
          server_connection_id: context.connection.id,
          channel_membership_id: context.membership.id,
          kind: "message",
          nick: "akash",
          metadata: %{},
          body: "message #{index}",
          mentioned: false,
          occurred_at: DateTime.add(timestamp, index, :second),
          inserted_at: timestamp,
          updated_at: timestamp
        }
      end)

    assert {151, nil} = Repo.insert_all(Message, rows)
    buffer_id = "channel:#{context.membership.id}"

    assert 150 ==
             context.user
             |> MessageHistory.list_buffer_messages(buffer_id, limit: "999")
             |> length()

    assert 150 ==
             context.user
             |> MessageHistory.list_buffer_messages(buffer_id, limit: "malformed")
             |> length()

    assert [%{body: "message 151"}] =
             MessageHistory.list_buffer_messages(context.user, buffer_id, limit: "0")
  end

  test "filters, deduplicates, and caps command repair ids", context do
    buffer_id = "server:#{context.connection.id}"

    command_ids = Enum.map(1..51, &"command-#{&1}")

    messages =
      for index <- [1, 50, 51], into: %{} do
        command_id = "command-#{index}"

        assert {:ok, message} =
                 Chat.record_command_message(
                   context.connection,
                   buffer_id,
                   "command #{index}",
                   %{
                     command_id: command_id,
                     command: "LIST",
                     command_status: "completed"
                   }
                 )

        {index, message}
      end

    assert {:ok, _result} =
             Chat.record_command_message(
               context.connection,
               buffer_id,
               "result row",
               %{
                 command_id: "command-1",
                 command: "LIST",
                 command_status: "result"
               }
             )

    requested_ids = ["command-1", "command-1", 123 | Enum.drop(command_ids, 1)]

    assert [messages[1].id, messages[50].id] ==
             context.user
             |> MessageHistory.list_buffer_command_messages(buffer_id, requested_ids)
             |> Enum.map(& &1.id)
  end

  defp insert_channel_messages(context, messages) do
    Enum.map(messages, fn {body, occurred_at} ->
      insert_message(
        context.user,
        context.connection,
        context.membership,
        body,
        occurred_at
      )
    end)
  end

  defp insert_message(user, connection, membership, body, occurred_at) do
    %Message{
      user_id: user.id,
      server_connection_id: connection.id,
      channel_membership_id: membership.id
    }
    |> Message.changeset(%{
      kind: "message",
      nick: "akash",
      body: body,
      occurred_at: occurred_at
    })
    |> Repo.insert!()
  end
end
