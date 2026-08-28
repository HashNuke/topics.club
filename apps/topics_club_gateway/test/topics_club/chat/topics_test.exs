defmodule TopicsClub.Chat.TopicsTest do
  use TopicsClubWeb.DataCase, async: true

  alias TopicsClub.AccountsFixtures
  alias TopicsClub.Chat.Connections
  alias TopicsClub.Chat.Topic
  alias TopicsClub.Chat.Topics
  alias TopicsClub.Irc.Identifier
  alias TopicsClub.Repo

  test "development topics point at the local IRC server" do
    topics = [
      %{
        name: "#elixir",
        description: "Local Elixir discussion.",
        server_host: "127.0.0.1",
        server_port: 6669,
        use_tls: false,
        channel: "#elixir",
        sort_order: 10
      },
      %{
        name: "#phoenix",
        description: "Local Phoenix discussion.",
        server_host: "127.0.0.1",
        server_port: 6669,
        use_tls: false,
        channel: "#phoenix",
        sort_order: 20
      }
    ]

    inserted_topics = Enum.map(topics, &Repo.insert!(Topic.changeset(%Topic{}, &1)))

    listed = Topics.list()
    ordering = Enum.map(listed, &{&1.sort_order, &1.name})
    assert ordering == Enum.sort(ordering)
    assert Enum.map(listed, & &1.server_host) |> Enum.uniq() == ["127.0.0.1"]
    assert Enum.map(listed, & &1.use_tls) |> Enum.uniq() == [false]

    assert Enum.all?(inserted_topics, fn topic ->
             Topics.get!(topic.id).name == topic.name
           end)
  end

  test "joins with an IRC-safe default nickname" do
    user = AccountsFixtures.user_fixture(%{email: "3dev@example.com"})
    topic = insert_topic()

    assert {:ok, %{connection: connection, topic: ^topic}} = Topics.join(user, topic)
    assert connection.nickname == "u_3dev"
    assert Identifier.valid_nick?(connection.nickname)
  end

  test "repairs an existing invalid nickname before joining" do
    user = AccountsFixtures.user_fixture(%{email: "3dev@example.com"})

    assert {:ok, connection} =
             Connections.create(user, %{
               "name" => "127.0.0.1",
               "host" => "127.0.0.1",
               "port" => 6669,
               "use_tls" => false,
               "nickname" => "3dev",
               "status" => "connecting"
             })

    topic = insert_topic()

    assert {:ok, %{connection: repaired, topic: ^topic}} = Topics.join(user, topic)
    assert repaired.id == connection.id
    assert repaired.nickname == "u_3dev"
    assert repaired.status == "disconnected"
  end

  defp insert_topic do
    Repo.insert!(
      Topic.changeset(%Topic{}, %{
        name: "#elixir",
        description: "Local Elixir discussion.",
        server_host: "127.0.0.1",
        server_port: 6669,
        use_tls: false,
        channel: "#elixir",
        sort_order: 10
      })
    )
  end
end
