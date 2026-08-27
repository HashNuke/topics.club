defmodule Ircpipe.Chat.ReadStateTest do
  use Ircpipe.DataCase, async: true

  alias Ircpipe.AccountsFixtures

  alias Ircpipe.Chat.{
    Connections,
    MessageIngestion,
    Notification,
    ReadState
  }

  alias Ircpipe.Repo

  test "marks owned channel and server buffers read" do
    user = AccountsFixtures.user_fixture()
    connection = connection_fixture(user)
    {:ok, membership} = Ircpipe.Chat.join_channel(user, connection, "#elixir")

    {:ok, message} =
      MessageIngestion.record_channel(connection, membership.channel, "akash", "mira: ping")

    notification = Repo.get_by!(Notification, message_id: message.id)

    assert :ok = ReadState.mark(user, Repo.reload!(membership))
    persisted_membership = Repo.reload!(membership)
    assert persisted_membership.unread_count == 0
    assert persisted_membership.mention_count == 0
    assert persisted_membership.last_read_at
    assert Repo.reload!(notification).read_at

    MessageIngestion.record_server(connection, "Connected")
    assert :ok = ReadState.mark(user, Repo.reload!(connection))
    persisted_connection = Repo.reload!(connection)
    assert persisted_connection.unread_count == 0
    assert persisted_connection.last_read_at
  end

  test "rejects buffers owned by another user" do
    owner = AccountsFixtures.user_fixture()
    other_user = AccountsFixtures.user_fixture()
    connection = connection_fixture(owner)
    {:ok, membership} = Ircpipe.Chat.join_channel(owner, connection, "#elixir")

    assert {:error, :invalid_buffer} = ReadState.mark(other_user, membership)
    assert {:error, :invalid_buffer} = ReadState.mark(other_user, connection)
  end

  test "rejects an outer transaction before updating or publishing" do
    user = AccountsFixtures.user_fixture()
    connection = connection_fixture(user)
    {:ok, membership} = Ircpipe.Chat.join_channel(user, connection, "#elixir")

    {:ok, _message} =
      MessageIngestion.record_channel(connection, membership.channel, "akash", "mira: ping")

    {:ok, _server_message} = MessageIngestion.record_server(connection, "Connected")
    Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{user.id}")

    assert {:error, :forced_rollback} =
             Repo.transaction(fn ->
               assert_raise ArgumentError,
                            ~r/cannot mark buffers read inside an existing transaction/,
                            fn ->
                              ReadState.mark(user, Repo.reload!(membership))
                            end

               assert_raise ArgumentError,
                            ~r/cannot mark buffers read inside an existing transaction/,
                            fn ->
                              ReadState.mark(user, Repo.reload!(connection))
                            end

               Repo.rollback(:forced_rollback)
             end)

    assert Repo.reload!(membership).unread_count == 1
    assert Repo.reload!(connection).unread_count == 1
    refute_received {:buffer_read, _payload}
  end

  defp connection_fixture(user) do
    {:ok, connection} =
      Connections.create(user, %{
        "name" => "read-state-test",
        "host" => "irc.example.com",
        "nickname" => "mira"
      })

    connection
  end
end
