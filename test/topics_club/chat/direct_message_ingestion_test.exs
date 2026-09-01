defmodule TopicsClub.Chat.DirectMessageIngestionTest do
  use TopicsClub.DataCase, async: true

  alias TopicsClub.AccountsFixtures

  alias TopicsClub.Chat.{
    Connections,
    DirectMessageIngestion,
    DirectMessageThread,
    Message,
    Notification
  }

  alias TopicsClub.Repo

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

  test "applies a replayed Wirekeeper direct-message effect exactly once" do
    user = AccountsFixtures.user_fixture()
    connection = connection_fixture(user)
    Phoenix.PubSub.subscribe(TopicsClub.PubSub, "user:#{user.id}")

    ingestion = %{
      generation: "generation-1",
      sequence: 44,
      effect_key: "message:0"
    }

    assert {:ok, %{thread: thread, message: message, notification: notification}} =
             DirectMessageIngestion.record(
               connection,
               "akash",
               "akash",
               "private line exactly once",
               "message",
               %{direction: "incoming", account: "account-a"},
               :rfc1459,
               ingestion
             )

    assert_receive {:direct_message_thread, _payload}
    assert_receive {:buffer_message, %{id: message_id}}
    assert message_id == message.id

    assert {:ok, nil} =
             DirectMessageIngestion.record(
               connection,
               "akash",
               "akash",
               "private line exactly once",
               "message",
               %{direction: "incoming", account: "account-a"},
               :rfc1459,
               ingestion
             )

    refute_receive {:direct_message_thread, _payload}, 50
    refute_receive {:buffer_message, _payload}, 50

    assert Repo.aggregate(
             from(m in Message, where: m.body == "private line exactly once"),
             :count
           ) == 1

    assert Repo.aggregate(from(n in Notification, where: n.id == ^notification.id), :count) == 1
    assert Repo.get!(DirectMessageThread, thread.id).unread_count == 1
  end

  test "rejects an outer transaction before persistence, delivery, or publication" do
    user = AccountsFixtures.user_fixture()
    connection = connection_fixture(user)
    Phoenix.PubSub.subscribe(TopicsClub.PubSub, "user:#{user.id}")

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

  test "drops private traffic after the connection is marked for deletion" do
    user = AccountsFixtures.user_fixture()
    connection = connection_fixture(user)
    Phoenix.PubSub.subscribe(TopicsClub.PubSub, "user:#{user.id}")

    connection
    |> Ecto.Changeset.change(deleting: true)
    |> Repo.update!()

    initial_messages = Repo.aggregate(Message, :count)
    initial_notifications = Repo.aggregate(Notification, :count)
    initial_jobs = Repo.aggregate(Oban.Job, :count)

    assert {:error, :connection_deleting} =
             DirectMessageIngestion.record(
               connection,
               "akash",
               "akash",
               "never stored",
               "message",
               %{direction: "incoming"},
               :rfc1459
             )

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
