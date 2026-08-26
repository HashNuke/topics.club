defmodule Ircpipe.Discovery.RefresherTest do
  use Ircpipe.DataCase, async: true

  alias Ircpipe.Discovery
  alias Ircpipe.Discovery.Refresher

  test "refreshes a due network catalog and obtains channels from IRC" do
    now = ~U[2026-08-26 12:00:00Z]
    test_pid = self()

    fetch_networks = fn ->
      send(test_pid, :fetched_netsplit)

      {:ok,
       [
         %{
           name: "Local IRC",
           slug: "Local",
           host: "irc.local.test",
           port: 6667,
           use_tls: false,
           rank: 1,
           source_url: "https://netsplit.de/networks/Local/"
         }
       ]}
    end

    list_channels = fn network ->
      send(test_pid, {:listed_irc, network.host})
      {:ok, [%{name: "#elixir", topic: "Elixir", user_count: 42}]}
    end

    assert :ok =
             Refresher.run(now,
               fetch_networks: fetch_networks,
               list_channels: list_channels,
               max_concurrency: 1
             )

    assert_received :fetched_netsplit
    assert_received {:listed_irc, "irc.local.test"}

    assert [%{name: "#elixir", user_count: 42, network: %{name: "Local IRC"}}] =
             Discovery.list_popular_server_channels()
  end

  test "does no external work while both caches are fresh" do
    now = ~U[2026-08-26 12:00:00Z]

    {:ok, [network]} =
      Discovery.sync_networks(
        [
          %{
            name: "Local IRC",
            slug: "Local",
            host: "irc.local.test",
            port: 6667,
            use_tls: false,
            rank: 1,
            source_url: "https://netsplit.de/networks/Local/"
          }
        ],
        now
      )

    assert {:ok, 0} = Discovery.replace_server_channels(network, [], now)

    reject = fn -> flunk("network source should not be called") end
    reject_network = fn _network -> flunk("IRC LIST should not be called") end

    assert :ok =
             Refresher.run(now,
               fetch_networks: reject,
               list_channels: reject_network,
               max_concurrency: 1
             )
  end
end
