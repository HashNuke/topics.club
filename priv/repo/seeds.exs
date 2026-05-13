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
    name: "Elixir",
    description: "Phoenix, OTP, libraries, releases, and production Elixir.",
    server_host: "irc.libera.chat",
    server_port: 6697,
    use_tls: true,
    channel: "#elixir",
    sort_order: 10
  },
  %{
    name: "Phoenix",
    description: "Phoenix web apps, LiveView, channels, and deployment.",
    server_host: "irc.libera.chat",
    server_port: 6697,
    use_tls: true,
    channel: "#phoenixframework",
    sort_order: 20
  },
  %{
    name: "Open Source",
    description: "General open source discussion on Libera.Chat.",
    server_host: "irc.libera.chat",
    server_port: 6697,
    use_tls: true,
    channel: "#opensource",
    sort_order: 30
  }
]

Enum.each(topics, fn attrs ->
  unless Repo.get_by(Topic, server_host: attrs.server_host, channel: attrs.channel) do
    Repo.insert!(Topic.changeset(%Topic{}, attrs))
  end
end)
