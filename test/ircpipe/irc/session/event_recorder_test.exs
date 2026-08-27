defmodule Ircpipe.Irc.Session.EventRecorderTest do
  use Ircpipe.DataCase, async: true

  alias Ircpipe.AccountsFixtures
  alias Ircpipe.Chat
  alias Ircpipe.Chat.{Connections, MessageHistory, SystemMessages}
  alias Ircpipe.Irc.Session.EventRecorder

  test "records IRC errors in an existing channel buffer" do
    user = AccountsFixtures.user_fixture()
    connection = connection_fixture(user)
    assert {:ok, membership} = Chat.join_channel(user, connection, "#elixir")

    assert {:ok, message} =
             EventRecorder.irc_error(
               %{connection: connection, active_casemapping: :ascii},
               %{target: "#Elixir", reason: "Cannot join channel"}
             )

    assert message.channel_membership_id == membership.id
    assert message.kind == "error"
    assert message.body == "Cannot join channel"
  end

  test "falls back to the server buffer when an IRC error names an unknown channel" do
    user = AccountsFixtures.user_fixture()
    connection = connection_fixture(user)

    assert {:ok, _message} =
             EventRecorder.irc_error(
               %{connection: connection, active_casemapping: :ascii},
               %{target: "#missing", code: 403}
             )

    assert [message] = MessageHistory.list_buffer_messages(user, "server:#{connection.id}")
    assert message.channel_membership_id == nil
    assert message.kind == "error"
    assert message.body == "IRC error 403."
  end

  test "channel recording reports a missing membership explicitly" do
    user = AccountsFixtures.user_fixture()
    connection = connection_fixture(user)

    assert_raise Ecto.NoResultsError, fn ->
      SystemMessages.record(
        connection,
        "#missing",
        "error",
        nil,
        "Cannot join channel"
      )
    end
  end

  test "does not swallow unrelated malformed-state map errors" do
    assert_raise BadMapError, fn ->
      EventRecorder.irc_error([], %{target: "#missing", code: 403})
    end
  end

  defp connection_fixture(user) do
    assert {:ok, connection} =
             Connections.create(user, %{
               "name" => "event-recorder-#{System.unique_integer([:positive])}",
               "host" => "irc.events.test",
               "nickname" => "mira"
             })

    connection
  end
end
