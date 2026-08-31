defmodule TopicsClubWeb.Api.DiscoveryControllerTest do
  use TopicsClubWeb.ConnCase, async: false

  alias TopicsClub.Chat
  alias TopicsClub.Chat.Connections
  alias TopicsClub.Discovery
  alias TopicsClub.Irc.{Session, SessionLocator, SessionSupervisor}
  alias TopicsClub.IrcTestServer

  setup :register_and_log_in_user

  test "embeds curated featured channels in the public homepage" do
    now = ~U[2026-08-26 12:00:00Z]
    {:ok, [network]} = Discovery.sync_networks([network_entry()], now)

    {:ok, 4} =
      Discovery.replace_server_channels(
        network,
        [
          %{name: "#linux", topic: "Linux discussion", user_count: 1_800},
          %{name: "#python", topic: "Python discussion", user_count: 1_200},
          %{name: "#ruby", topic: "Ruby discussion", user_count: 420},
          %{name: "#popular", topic: "Popular fallback", user_count: 2_400}
        ],
        now
      )

    [featured_channels_json] =
      build_conn()
      |> get(~p"/")
      |> html_response(200)
      |> LazyHTML.from_document()
      |> LazyHTML.query("#topics-club-root")
      |> LazyHTML.attribute("data-featured-channels")

    server_channels = Jason.decode!(featured_channels_json)

    assert Enum.map(server_channels, & &1["name"]) == [
             "#ruby",
             "#python",
             "#linux",
             "#popular"
           ]
  end

  test "returns the complete cached catalog ordered by users", %{conn: conn} do
    now = ~U[2026-08-26 12:00:00Z]
    {:ok, [network]} = Discovery.sync_networks([network_entry()], now)

    {:ok, 2} =
      Discovery.replace_server_channels(
        network,
        [
          %{name: "#quiet", topic: "A small room", user_count: 4},
          %{name: "#elixir", topic: "Elixir and OTP", user_count: 42}
        ],
        now
      )

    conn = get(conn, ~p"/api/discovery/server_channels")

    assert %{
             "server_channels" => [
               %{
                 "id" => channel_id,
                 "name" => "#elixir",
                 "topic" => "Elixir and OTP",
                 "user_count" => 42,
                 "network_id" => network_id,
                 "network_name" => "Local IRC",
                 "server_host" => "127.0.0.1",
                 "server_port" => 6667,
                 "use_tls" => false,
                 "refreshed_at" => "2026-08-26T12:00:00Z"
               },
               %{"name" => "#quiet", "user_count" => 4}
             ]
           } = json_response(conn, 200)

    assert is_integer(channel_id)
    assert network_id == network.id
  end

  test "searches and paginates the cached catalog remotely in groups of 25", %{conn: conn} do
    now = ~U[2026-08-26 12:00:00Z]
    {:ok, [network]} = Discovery.sync_networks([network_entry()], now)

    channels =
      Enum.map(1..30, fn index ->
        %{
          name: "#channel-#{index}",
          topic: if(index == 30, do: "Needle discussion", else: "General discussion"),
          user_count: 100 - index
        }
      end)

    assert {:ok, 30} = Discovery.replace_server_channels(network, channels, now)

    page_conn = get(conn, ~p"/api/discovery/server_channels?page=2")
    page_response = json_response(page_conn, 200)

    assert page_response["page"] == 2
    assert page_response["page_size"] == 25
    assert page_response["total_channels"] == 30
    assert page_response["total_pages"] == 2
    assert length(page_response["server_channels"]) == 5

    search_conn = get(conn, ~p"/api/discovery/server_channels?query=needle")

    assert %{
             "page" => 1,
             "query" => "needle",
             "total_channels" => 1,
             "total_pages" => 1,
             "server_channels" => [%{"name" => "#channel-30"}]
           } = json_response(search_conn, 200)
  end

  test "ignores the legacy connection filter for the cached catalog", %{
    conn: conn,
    user: user
  } do
    now = ~U[2026-08-26 12:00:00Z]
    local = network_entry()
    remote = %{local | name: "Remote IRC", slug: "Remote", host: "irc.remote.test", rank: 2}
    {:ok, [local_network, remote_network]} = Discovery.sync_networks([local, remote], now)

    assert {:ok, 1} =
             Discovery.replace_server_channels(
               local_network,
               [%{name: "#local", topic: "Local", user_count: 10}],
               now
             )

    assert {:ok, 1} =
             Discovery.replace_server_channels(
               remote_network,
               [%{name: "#remote", topic: "Remote", user_count: 20}],
               now
             )

    {:ok, connection} =
      Connections.create(user, %{
        "name" => "local discovery",
        "host" => local.host,
        "port" => local.port,
        "use_tls" => local.use_tls
      })

    scoped_conn =
      get(conn, "/api/discovery/server_channels?connection_id=#{connection.id}")

    assert %{
             "total_channels" => 2,
             "server_channels" => [%{"name" => "#remote"}, %{"name" => "#local"}]
           } = json_response(scoped_conn, 200)
  end

  test "connects to the cached network and joins the selected channel", %{
    conn: conn,
    user: user
  } do
    server = start_supervised!({IrcTestServer, self()})
    now = ~U[2026-08-26 12:00:00Z]

    {:ok, [network]} =
      Discovery.sync_networks(
        [%{network_entry() | port: IrcTestServer.port(server)}],
        now
      )

    {:ok, 1} =
      Discovery.replace_server_channels(
        network,
        [%{name: "#elixir", topic: "Elixir and OTP", user_count: 42}],
        now
      )

    {:ok, existing_connection} =
      Connections.create(user, %{
        "name" => "127.0.0.1",
        "host" => "127.0.0.1",
        "port" => IrcTestServer.port(server),
        "use_tls" => false
      })

    [server_channel] = Discovery.list_popular_server_channels()
    conn = post(conn, ~p"/api/discovery/server_channels/#{server_channel.id}/join")

    assert %{
             "connection" => %{
               "id" => connection_id,
               "host" => "127.0.0.1",
               "name" => "127.0.0.1"
             },
             "buffer" => %{
               "buffer_id" => "channel:" <> _,
               "title" => "#elixir"
             }
           } = json_response(conn, 202)

    assert_receive {:irc_server_line, "NICK " <> _nickname}, 1_000
    assert_receive {:irc_server_line, "USER " <> _rest}, 1_000
    assert_receive {:irc_server_line, "JOIN #elixir"}, 1_000

    connection = Connections.get!(user, connection_id)
    assert connection.id == existing_connection.id
    assert connection.host == "127.0.0.1"
    assert length(Connections.list(user)) == 1
    assert :ok = Session.quit(connection)
  end

  test "returns an already-joined channel without sending another JOIN", %{
    conn: conn,
    user: user
  } do
    server = start_supervised!({IrcTestServer, self()})
    now = ~U[2026-08-26 12:00:00Z]
    port = IrcTestServer.port(server)

    {:ok, [network]} =
      Discovery.sync_networks([%{network_entry() | port: port}], now)

    {:ok, 1} =
      Discovery.replace_server_channels(
        network,
        [%{name: "#elixir", topic: "Elixir and OTP", user_count: 42}],
        now
      )

    {:ok, connection} =
      Connections.create(user, %{
        "name" => "existing",
        "host" => "127.0.0.1",
        "port" => port,
        "use_tls" => false
      })

    {:ok, _membership} = Chat.join_channel(user, connection, "#elixir")
    connection = Connections.get!(user, connection.id)
    Phoenix.PubSub.subscribe(TopicsClub.PubSub, "user:#{user.id}")
    {:ok, _pid} = SessionSupervisor.start_session(connection)

    assert_receive {:irc_server_line, "NICK " <> _nickname}, 1_000
    assert_receive {:irc_server_line, "USER " <> _rest}, 1_000
    assert_receive {:irc_server_line, "JOIN #elixir"}, 1_000
    assert_receive {:presence_sync, %{buffer_id: "channel:" <> _}}, 1_000
    _state = :sys.get_state(SessionLocator.via(connection))

    [server_channel] = Discovery.list_popular_server_channels()
    conn = post(conn, ~p"/api/discovery/server_channels/#{server_channel.id}/join")

    assert %{
             "connection" => %{"id" => connection_id},
             "buffer" => %{"title" => "#elixir"},
             "status" => "sent"
           } = json_response(conn, 200)

    assert connection_id == connection.id
    refute_receive {:irc_server_line, "JOIN #elixir"}
    assert :ok = Session.quit(connection)
  end

  defp network_entry do
    %{
      name: "Local IRC",
      slug: "Local",
      host: "127.0.0.1",
      port: 6667,
      use_tls: false,
      rank: 1,
      source_url: "https://netsplit.de/networks/Local/"
    }
  end
end
