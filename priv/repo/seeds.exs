# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# Inside the script, you can read and write to any of your
# repositories directly:
#
#     Ircpipe.Repo.insert!(%Ircpipe.SomeSchema{})
#
# We recommend using the bang functions (`insert!`, `update!`
# and so on) as they will fail if something goes wrong.

alias Ircpipe.Chat.Topic
alias Ircpipe.Repo

topics = [
  %{
    name: "#elixir",
    description: "Local Elixir discussion for development and testing.",
    server_host: "127.0.0.1",
    server_port: 6667,
    use_tls: false,
    channel: "#elixir",
    sort_order: 10
  },
  %{
    name: "#phoenix",
    description: "Local Phoenix discussion for development and testing.",
    server_host: "127.0.0.1",
    server_port: 6667,
    use_tls: false,
    channel: "#phoenix",
    sort_order: 20
  },
  %{
    name: "#testing",
    description: "Local testing channel for irssi and automated checks.",
    server_host: "127.0.0.1",
    server_port: 6667,
    use_tls: false,
    channel: "#testing",
    sort_order: 30
  }
]

Enum.each(topics, fn attrs ->
  unless Repo.get_by(Topic, server_host: attrs.server_host, channel: attrs.channel) do
    Repo.insert!(Topic.changeset(%Topic{}, attrs))
  end
end)
