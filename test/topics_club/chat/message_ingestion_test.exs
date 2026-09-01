defmodule TopicsClub.Chat.MessageIngestionTest do
  use TopicsClub.DataCase, async: true

  alias TopicsClub.AccountsFixtures
  alias TopicsClub.Chat

  alias TopicsClub.Chat.{
    ChannelMembership,
    Connections,
    IrcIngestionEffect,
    Message,
    MessageIngestion,
    Notification
  }

  alias TopicsClub.Repo

  test "records channel mentions and server lines in their owned buffers" do
    user = AccountsFixtures.user_fixture()
    connection = connection_fixture(user)
    {:ok, membership} = Chat.join_channel(user, connection, "#elixir")
    Phoenix.PubSub.subscribe(TopicsClub.PubSub, "user:#{user.id}")

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

  test "commits an ordinary message before direct publication without an Oban job" do
    user = AccountsFixtures.user_fixture()
    connection = connection_fixture(user)
    {:ok, membership} = Chat.join_channel(user, connection, "#elixir")
    Phoenix.PubSub.subscribe(TopicsClub.PubSub, "user:#{user.id}")
    initial_jobs = Repo.aggregate(Oban.Job, :count)

    assert {:ok, message} =
             MessageIngestion.record_channel(
               connection,
               membership.channel,
               "akash",
               "ordinary message"
             )

    assert_receive {:buffer_message, %{id: message_id, body: "ordinary message"}}
    assert message_id == message.id
    assert Repo.get!(Message, message_id).body == "ordinary message"
    assert Repo.aggregate(Oban.Job, :count) == initial_jobs
  end

  test "applies a replayed Wirekeeper channel effect exactly once" do
    user = AccountsFixtures.user_fixture()
    connection = connection_fixture(user)
    {:ok, membership} = Chat.join_channel(user, connection, "#elixir")
    Phoenix.PubSub.subscribe(TopicsClub.PubSub, "user:#{user.id}")

    ingestion = %{
      generation: "generation-1",
      sequence: 42,
      effect_key: "message:0"
    }

    assert {:ok, message} =
             MessageIngestion.record_channel(
               connection,
               membership.channel,
               "akash",
               "mira: exactly once",
               "message",
               %{},
               :rfc1459,
               ingestion
             )

    assert_receive {:buffer_message, %{id: message_id}}
    assert message_id == message.id

    membership
    |> Ecto.Changeset.change(status: "pending")
    |> Repo.update!()

    assert {:ok, nil} =
             MessageIngestion.record_channel(
               connection,
               membership.channel,
               "akash",
               "mira: exactly once",
               "message",
               %{},
               :rfc1459,
               ingestion
             )

    refute_receive {:buffer_message, _payload}, 50
    assert Repo.aggregate(from(m in Message, where: m.body == "mira: exactly once"), :count) == 1

    assert Repo.aggregate(from(n in Notification, where: n.message_id == ^message.id), :count) ==
             1

    current_membership = Repo.get!(ChannelMembership, membership.id)
    assert current_membership.unread_count == 1
    assert current_membership.mention_count == 1

    assert :ok =
             IrcIngestionEffect.release_many([
               {connection.id, ingestion.generation, ingestion.sequence}
             ])

    refute Repo.get_by(IrcIngestionEffect,
             server_connection_id: connection.id,
             wirekeeper_generation: ingestion.generation,
             wirekeeper_sequence: ingestion.sequence
           )
  end

  test "applies a replayed Wirekeeper server effect exactly once" do
    user = AccountsFixtures.user_fixture()
    connection = connection_fixture(user)
    Phoenix.PubSub.subscribe(TopicsClub.PubSub, "user:#{user.id}")

    ingestion = %{
      generation: "generation-1",
      sequence: 43,
      effect_key: "message:0"
    }

    assert {:ok, message} =
             MessageIngestion.record_server(
               connection,
               "server line exactly once",
               "notice",
               "irc.example.com",
               %{},
               ingestion
             )

    assert_receive {:buffer_message, %{id: message_id}}
    assert message_id == message.id

    assert {:ok, nil} =
             MessageIngestion.record_server(
               connection,
               "server line exactly once",
               "notice",
               "irc.example.com",
               %{},
               ingestion
             )

    refute_receive {:buffer_message, _payload}, 50

    assert Repo.aggregate(
             from(m in Message, where: m.body == "server line exactly once"),
             :count
           ) == 1

    assert Repo.get!(TopicsClub.Chat.ServerConnection, connection.id).unread_count == 1
  end

  test "rejects outer transactions before persistence, delivery, or publication" do
    user = AccountsFixtures.user_fixture()
    connection = connection_fixture(user)
    {:ok, membership} = Chat.join_channel(user, connection, "#elixir")
    Phoenix.PubSub.subscribe(TopicsClub.PubSub, "user:#{user.id}")

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
    Phoenix.PubSub.subscribe(TopicsClub.PubSub, "user:#{user.id}")

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
    Phoenix.PubSub.subscribe(TopicsClub.PubSub, "user:#{user.id}")

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
