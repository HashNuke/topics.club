defmodule Ircpipe.Chat.MessageIngestionTest do
  use Ircpipe.DataCase, async: true

  alias Ircpipe.AccountsFixtures
  alias Ircpipe.Chat
  alias Ircpipe.Chat.{Connections, Message, MessageIngestion, Notification}
  alias Ircpipe.Repo

  test "records channel mentions and server lines in their owned buffers" do
    user = AccountsFixtures.user_fixture()
    connection = connection_fixture(user)
    {:ok, membership} = Chat.join_channel(user, connection, "#elixir")
    Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{user.id}")

    assert {:ok, channel_message} =
             MessageIngestion.record_channel(
               connection,
               membership.channel,
               "akash",
               "mira: ping"
             )

    assert channel_message.mentioned
    assert channel_message.channel_membership_id == membership.id

    assert_receive {:buffer_message, %{unread_count: 1, mention_count: 1}}

    assert Repo.get_by!(Notification, message_id: channel_message.id).channel_membership_id ==
             membership.id

    assert {:ok, server_message} = MessageIngestion.record_server(connection, "Connected")
    assert server_message.server_connection_id == connection.id
    assert server_message.channel_membership_id == nil
  end

  test "rejects outer transactions before persistence, delivery, or publication" do
    user = AccountsFixtures.user_fixture()
    connection = connection_fixture(user)
    {:ok, membership} = Chat.join_channel(user, connection, "#elixir")
    Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{user.id}")

    initial_messages = Repo.aggregate(Message, :count)
    initial_notifications = Repo.aggregate(Notification, :count)
    initial_jobs = Repo.aggregate(Oban.Job, :count)

    assert {:error, :forced_rollback} =
             Repo.transaction(fn ->
               assert_raise ArgumentError,
                            ~r/cannot ingest messages inside an existing transaction/,
                            fn ->
                              MessageIngestion.record_channel(
                                connection,
                                membership.channel,
                                "akash",
                                "mira: never stored"
                              )
                            end

               assert_raise ArgumentError,
                            ~r/cannot ingest messages inside an existing transaction/,
                            fn ->
                              MessageIngestion.record_server(connection, "never stored")
                            end

               Repo.rollback(:forced_rollback)
             end)

    assert Repo.aggregate(Message, :count) == initial_messages
    assert Repo.aggregate(Notification, :count) == initial_notifications
    assert Repo.aggregate(Oban.Job, :count) == initial_jobs
    refute_received {:buffer_system, _payload}
  end

  test "drops channel and server traffic after the connection is marked for deletion" do
    user = AccountsFixtures.user_fixture()
    connection = connection_fixture(user)
    {:ok, membership} = Chat.join_channel(user, connection, "#elixir")
    Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{user.id}")

    connection
    |> Ecto.Changeset.change(deleting: true)
    |> Repo.update!()

    initial_messages = Repo.aggregate(Message, :count)
    initial_notifications = Repo.aggregate(Notification, :count)
    initial_jobs = Repo.aggregate(Oban.Job, :count)

    assert {:error, :connection_deleting} =
             MessageIngestion.record_channel(
               connection,
               membership.channel,
               "akash",
               "mira: never stored"
             )

    assert {:error, :connection_deleting} =
             MessageIngestion.record_server(connection, "never stored")

    assert Repo.aggregate(Message, :count) == initial_messages
    assert Repo.aggregate(Notification, :count) == initial_notifications
    assert Repo.aggregate(Oban.Job, :count) == initial_jobs
    refute_received {:buffer_system, _payload}
  end

  test "reports a missing channel membership without persisting or publishing" do
    user = AccountsFixtures.user_fixture()
    connection = connection_fixture(user)
    Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{user.id}")

    assert {:error, :channel_membership_not_found} =
             MessageIngestion.record_channel(
               connection,
               "#missing",
               "akash",
               "late channel line"
             )

    refute Repo.get_by(Message, body: "late channel line")
    refute_received {:buffer_message, _payload}
  end

  defp connection_fixture(user) do
    {:ok, connection} =
      Connections.create(user, %{
        "name" => "message-ingestion-test",
        "host" => "irc.example.com",
        "nickname" => "mira"
      })

    connection
  end
end
