defmodule TopicsClub.Discovery.ServerChannelListerTest do
  use ExUnit.Case, async: true

  alias TopicsClub.Discovery.ServerChannelLister
  alias TopicsClub.Discovery.Network
  alias TopicsClub.IrcTestServer

  test "gets channel names, topics, and user counts through IRC LIST" do
    server = start_supervised!({IrcTestServer, self()})

    network = %Network{
      name: "Local IRC",
      host: "127.0.0.1",
      port: IrcTestServer.port(server),
      use_tls: false
    }

    assert {:ok, channels} = ServerChannelLister.fetch(network, timeout: 1_000)

    assert channels == [
             %{name: "#elixir", topic: "Elixir, OTP, and Phoenix", user_count: 42},
             %{name: "#quiet", topic: "A smaller conversation", user_count: 4},
             %{name: "&local", topic: "A local-only channel", user_count: 3}
           ]

    assert_receive {:irc_server_line, "LIST"}, 1_000
  end
end
