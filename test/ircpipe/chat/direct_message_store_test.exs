defmodule Ircpipe.Chat.DirectMessageStoreTest do
  use Ircpipe.DataCase, async: true

  alias Ircpipe.AccountsFixtures

  alias Ircpipe.Chat.{
    Connections,
    DirectMessageStore,
    DirectMessageThread,
    Message,
    Notification
  }

  alias Ircpipe.Repo

  test "creates, lists, and loads direct-message threads for one user connection" do
    user = AccountsFixtures.user_fixture()
    connection = connection_fixture(user)

    zed = ensure_thread!(user, connection, "Zed")
    akash = ensure_thread!(user, connection, "akash")

    assert Enum.map(DirectMessageStore.list_open(user, connection), & &1.id) == [
             akash.id,
             zed.id
           ]

    loaded = DirectMessageStore.get!(user, zed.id)
    assert loaded.server_connection.id == connection.id
  end

  test "thread changes increment the mutation revision" do
    thread = %DirectMessageThread{mutation_revision: 7}
    changeset = DirectMessageStore.changeset(thread, %{peer_nick: "mira"})

    assert Ecto.Changeset.get_change(changeset, :mutation_revision) == 8
    assert Ecto.Changeset.get_change(changeset, :peer_nick) == "mira"
  end

  test "recognizes archived peer keys" do
    assert DirectMessageStore.archived?(%DirectMessageThread{peer_key: "archived:12:mira"})
    refute DirectMessageStore.archived?(%DirectMessageThread{peer_key: "mira"})
    refute DirectMessageStore.archived?(%DirectMessageThread{peer_key: nil})
  end

  test "rejects a connection owned by another user" do
    owner = AccountsFixtures.user_fixture()
    other_user = AccountsFixtures.user_fixture()
    connection = connection_fixture(owner)

    assert_raise FunctionClauseError, fn ->
      Repo.transaction(fn ->
        DirectMessageStore.ensure_thread(other_user, connection, "mira", %{}, false, :ascii)
      end)
    end
  end

  test "collision-sensitive mutations require an explicit transaction" do
    user = AccountsFixtures.user_fixture()
    connection = connection_fixture(user)

    assert_raise ArgumentError, ~r/active database transaction/, fn ->
      DirectMessageStore.ensure_thread(user, connection, "mira", %{}, false, :ascii)
    end

    thread = ensure_thread!(user, connection, "mira")

    assert_raise ArgumentError, ~r/active database transaction/, fn ->
      DirectMessageStore.archive(thread)
    end
  end

  test "archives a thread and marks its unread notifications read" do
    user = AccountsFixtures.user_fixture()
    connection = connection_fixture(user)

    thread = ensure_thread!(user, connection, "mira")
    notification = notification_fixture(user, connection, thread)

    assert {:ok, archived} = Repo.transaction(fn -> DirectMessageStore.archive(thread) end)

    assert archived.closed_at
    assert archived.last_read_at
    assert archived.unread_count == 0
    assert DirectMessageStore.archived?(archived)
    assert Repo.reload!(thread).peer_key == archived.peer_key
    assert Repo.reload!(notification).read_at
  end

  test "archive changes roll back together" do
    user = AccountsFixtures.user_fixture()
    connection = connection_fixture(user)
    thread = ensure_thread!(user, connection, "mira")
    notification = notification_fixture(user, connection, thread)

    assert {:error, :forced_rollback} =
             Repo.transaction(fn ->
               archived = DirectMessageStore.archive(thread)
               assert DirectMessageStore.archived?(archived)
               assert Repo.reload!(notification).read_at
               Repo.rollback(:forced_rollback)
             end)

    persisted_thread = Repo.reload!(thread)
    refute DirectMessageStore.archived?(persisted_thread)
    assert persisted_thread.closed_at == nil
    assert Repo.reload!(notification).read_at == nil
  end

  defp ensure_thread!(user, connection, peer_nick) do
    assert {:ok, {:ok, thread, []}} =
             Repo.transaction(fn ->
               DirectMessageStore.ensure_thread(
                 user,
                 connection,
                 peer_nick,
                 %{},
                 false,
                 :ascii
               )
             end)

    thread
  end

  defp notification_fixture(user, connection, thread) do
    now = DateTime.utc_now(:second)

    message =
      Repo.insert!(%Message{
        user_id: user.id,
        server_connection_id: connection.id,
        direct_message_thread_id: thread.id,
        body: "unread",
        occurred_at: now
      })

    Repo.insert!(%Notification{
      user_id: user.id,
      message_id: message.id,
      direct_message_thread_id: thread.id
    })
  end

  defp connection_fixture(user) do
    {:ok, connection} =
      Connections.create(user, %{
        "name" => "store-test",
        "host" => "irc.example.com",
        "nickname" => "mira"
      })

    connection
  end
end
