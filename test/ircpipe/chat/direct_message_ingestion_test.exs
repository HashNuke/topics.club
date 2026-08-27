defmodule Ircpipe.Chat.DirectMessageIngestionTest do
  use Ircpipe.DataCase, async: true

  alias Ircpipe.AccountsFixtures

  alias Ircpipe.Chat.{
    Connections,
    DirectMessageIngestion,
    Message,
    Notification
  }

  alias Ircpipe.Repo

  test "persists an incoming private message and its unread notification" do
    user = AccountsFixtures.user_fixture()
    connection = connection_fixture(user)

    assert {:ok, %{thread: thread, message: message, notification: notification, notify?: true}} =
             DirectMessageIngestion.record(
               connection,
               "akash",
               "akash",
               "hello privately",
               "message",
               %{direction: "incoming", account: "account-a"},
               :rfc1459
             )

    assert thread.unread_count == 1
    assert message.direct_message_thread_id == thread.id
    assert message.body == "hello privately"
    assert notification.direct_message_thread_id == thread.id
    assert Repo.get!(Notification, notification.id).read_at == nil
  end

  test "rejects an outer transaction before persistence, delivery, or publication" do
    user = AccountsFixtures.user_fixture()
    connection = connection_fixture(user)
    Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{user.id}")

    initial_messages = Repo.aggregate(Message, :count)
    initial_notifications = Repo.aggregate(Notification, :count)
    initial_jobs = Repo.aggregate(Oban.Job, :count)

    assert {:error, :forced_rollback} =
             Repo.transaction(fn ->
               assert_raise ArgumentError, ~r/cannot ingest inside an existing transaction/, fn ->
                 DirectMessageIngestion.record(
                   connection,
                   "akash",
                   "akash",
                   "never stored",
                   "message",
                   %{direction: "incoming"},
                   :rfc1459
                 )
               end

               Repo.rollback(:forced_rollback)
             end)

    assert Repo.aggregate(Message, :count) == initial_messages
    assert Repo.aggregate(Notification, :count) == initial_notifications
    assert Repo.aggregate(Oban.Job, :count) == initial_jobs
    refute_received {:direct_message_thread, _payload}
    refute_received {:buffer_message, _payload}
  end

  defp connection_fixture(user) do
    {:ok, connection} =
      Connections.create(user, %{
        "name" => "ingestion-test",
        "host" => "irc.example.com",
        "nickname" => "local"
      })

    connection
  end
end
