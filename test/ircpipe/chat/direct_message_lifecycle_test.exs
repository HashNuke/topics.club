defmodule Ircpipe.Chat.DirectMessageLifecycleTest do
  use Ircpipe.DataCase, async: true

  alias Ircpipe.Accounts.Scope
  alias Ircpipe.AccountsFixtures
  alias Ircpipe.Chat.{Connections, DirectMessageLifecycle}

  test "owns direct-message thread opening, lookup, read state, and closing" do
    user = AccountsFixtures.user_fixture()
    scope = Scope.for_user(user)
    connection = connection_fixture(user)

    assert {:error, :invalid_nick} =
             DirectMessageLifecycle.open(user, connection, "not a nick")

    assert {:ok, thread} = DirectMessageLifecycle.open(user, connection, "mira")
    assert [listed] = DirectMessageLifecycle.list(user, connection)
    assert listed.id == thread.id
    assert DirectMessageLifecycle.get!(user, thread.id).server_connection.id == connection.id

    assert {:ok, read} = DirectMessageLifecycle.mark_read(scope, thread.id)
    assert read.unread_count == 0

    assert {:ok, closed} = DirectMessageLifecycle.close(scope, thread.id)
    assert closed.closed_at
    assert DirectMessageLifecycle.list(user, connection) == []
    assert {:error, :direct_message_closed} = DirectMessageLifecycle.mark_read(scope, thread.id)
  end

  defp connection_fixture(user) do
    {:ok, connection} =
      Connections.create(user, %{
        "name" => "lifecycle-test",
        "host" => "irc.example.com",
        "nickname" => "mira"
      })

    connection
  end
end
