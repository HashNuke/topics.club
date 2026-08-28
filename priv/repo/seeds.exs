# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# Inside the script, you can read and write to any of your
# repositories directly:
#
#     TopicsClub.Repo.insert!(%TopicsClub.SomeSchema{})
#
# We recommend using the bang functions (`insert!`, `update!`
# and so on) as they will fail if something goes wrong.

alias TopicsClub.Chat.{ServerConnection, Topic}
alias TopicsClub.Repo
import Ecto.Query

dev_irc_port = 6669

topics = [
  %{
    name: "#elixir",
    description: "Phoenix, OTP, releases, and production Elixir help.",
    server_host: "127.0.0.1",
    server_port: dev_irc_port,
    use_tls: false,
    channel: "#elixir",
    sort_order: 10
  },
  %{
    name: "#phoenix",
    description: "LiveView patterns, web UI questions, and framework support.",
    server_host: "127.0.0.1",
    server_port: dev_irc_port,
    use_tls: false,
    channel: "#phoenix",
    sort_order: 20
  },
  %{
    name: "#linux",
    description: "Daily Linux discussion, troubleshooting, and desktop setups.",
    server_host: "127.0.0.1",
    server_port: dev_irc_port,
    use_tls: false,
    channel: "#linux",
    sort_order: 30
  },
  %{
    name: "#rust",
    description: "Rust language help, async crates, and compiler talk.",
    server_host: "127.0.0.1",
    server_port: dev_irc_port,
    use_tls: false,
    channel: "#rust",
    sort_order: 40
  },
  %{
    name: "#gamedev",
    description: "Indie games, engines, shaders, and release feedback.",
    server_host: "127.0.0.1",
    server_port: dev_irc_port,
    use_tls: false,
    channel: "#gamedev",
    sort_order: 50
  },
  %{
    name: "#homelab",
    description: "Self-hosting, small servers, storage, and network projects.",
    server_host: "127.0.0.1",
    server_port: dev_irc_port,
    use_tls: false,
    channel: "#homelab",
    sort_order: 60
  },
  %{
    name: "#testing",
    description: "Local testing channel for irssi and automated checks.",
    server_host: "127.0.0.1",
    server_port: dev_irc_port,
    use_tls: false,
    channel: "#testing",
    sort_order: 70
  }
]

if Mix.env() in [:dev, :test] do
  ServerConnection
  |> where([connection], connection.host == "irc.libera.chat")
  |> Repo.delete_all()
end

Repo.delete_all(Topic)

Enum.each(topics, fn attrs ->
  Repo.insert!(Topic.changeset(%Topic{}, attrs))
end)
