defmodule TopicsClub.DiscoveryTest do
  use TopicsClubWeb.DataCase, async: true

  alias TopicsClub.Discovery

  test "syncs the current network catalog and deactivates networks outside the top set" do
    old_time = ~U[2026-08-01 12:00:00Z]
    now = ~U[2026-08-26 12:00:00Z]

    {:ok, [old]} =
      Discovery.sync_networks(
        [
          %{
            name: "OldNet",
            slug: "OldNet",
            host: "irc.old.test",
            port: 6667,
            use_tls: false,
            rank: 1,
            source_url: "https://netsplit.de/networks/OldNet/"
          }
        ],
        old_time
      )

    assert {:ok, [libera, oftc]} =
             Discovery.sync_networks(
               [
                 %{
                   name: "Libera.Chat",
                   slug: "Libera.Chat",
                   host: "irc.libera.chat",
                   port: 6697,
                   use_tls: true,
                   rank: 1,
                   source_url: "https://netsplit.de/networks/Libera.Chat/"
                 },
                 %{
                   name: "OFTC",
                   slug: "OFTC",
                   host: "irc.oftc.net",
                   port: 6697,
                   use_tls: true,
                   rank: 2,
                   source_url: "https://netsplit.de/networks/OFTC/"
                 }
               ],
               now
             )

    assert {libera.name, libera.rank, libera.source_refreshed_at} == {"Libera.Chat", 1, now}
    assert {oftc.name, oftc.rank} == {"OFTC", 2}
    refute Repo.reload!(old).active
  end

  test "replaces a network channel snapshot and lists channels globally by user count" do
    now = ~U[2026-08-26 12:00:00Z]
    {:ok, [libera, oftc]} = Discovery.sync_networks(network_entries(), now)

    assert {:ok, 2} =
             Discovery.replace_server_channels(
               libera,
               [
                 %{name: "#elixir", user_count: 420, topic: "Elixir and OTP"},
                 %{name: "#linux", user_count: 1_800, topic: "Linux discussion"}
               ],
               now
             )

    assert {:ok, 1} =
             Discovery.replace_server_channels(
               oftc,
               [
                 %{name: "#debian", user_count: 900, topic: "Debian support"}
               ],
               now
             )

    assert Enum.map(
             Discovery.list_popular_server_channels(),
             &{&1.name, &1.user_count, &1.network.name}
           ) ==
             [
               {"#linux", 1_800, "Libera.Chat"},
               {"#debian", 900, "OFTC"},
               {"#elixir", 420, "Libera.Chat"}
             ]

    assert {:ok, 1} =
             Discovery.replace_server_channels(
               libera,
               [%{name: "#beam", user_count: 80, topic: nil}],
               now
             )

    assert Enum.map(Discovery.list_popular_server_channels(), & &1.name) == ["#debian", "#beam"]
    assert Repo.reload!(libera).channels_refreshed_at == now
  end

  test "finds channel catalogs due after 24 hours and the network source due after 7 days" do
    now = ~U[2026-08-26 12:00:00Z]

    {:ok, [libera, oftc]} =
      Discovery.sync_networks(network_entries(), DateTime.add(now, -8, :day))

    {:ok, 0} =
      Discovery.replace_server_channels(libera, [], DateTime.add(now, -23, :hour))

    assert Enum.map(Discovery.networks_due_for_channel_refresh(now), & &1.id) == [oftc.id]
    assert Discovery.network_catalog_due?(now)
  end

  test "replaces invalid IRC text before persisting a server-channel snapshot" do
    now = ~U[2026-08-26 12:00:00Z]
    {:ok, [network | _rest]} = Discovery.sync_networks(network_entries(), now)

    assert {:ok, 1} =
             Discovery.replace_server_channels(
               network,
               [
                 %{name: <<"#caf", 0xE9>>, topic: <<"caf", 0xE9>>, user_count: 12},
                 %{name: <<"#caf", 0xF1>>, topic: "duplicate after repair", user_count: 4}
               ],
               now
             )

    assert [%{name: "#caf�", topic: "caf�"}] = Discovery.list_popular_server_channels()
  end

  defp network_entries do
    [
      %{
        name: "Libera.Chat",
        slug: "Libera.Chat",
        host: "irc.libera.chat",
        port: 6697,
        use_tls: true,
        rank: 1,
        source_url: "https://netsplit.de/networks/Libera.Chat/"
      },
      %{
        name: "OFTC",
        slug: "OFTC",
        host: "irc.oftc.net",
        port: 6697,
        use_tls: true,
        rank: 2,
        source_url: "https://netsplit.de/networks/OFTC/"
      }
    ]
  end
end
