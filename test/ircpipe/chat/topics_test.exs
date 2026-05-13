defmodule Ircpipe.Chat.TopicsTest do
  use Ircpipe.DataCase, async: true

  alias Ircpipe.Chat
  alias Ircpipe.Chat.Topic
  alias Ircpipe.Repo

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

    Enum.each(topics, &Repo.insert!(Topic.changeset(%Topic{}, &1)))

    assert Chat.list_topics() |> Enum.map(& &1.server_host) |> Enum.uniq() == ["127.0.0.1"]
    assert Chat.list_topics() |> Enum.map(& &1.use_tls) |> Enum.uniq() == [false]
  end
end
