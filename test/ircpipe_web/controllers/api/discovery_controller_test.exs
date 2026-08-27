defmodule IrcpipeWeb.Api.DiscoveryControllerTest do
  use IrcpipeWeb.ConnCase, async: false

  alias Ircpipe.Chat
  alias Ircpipe.Chat.Connections
  alias Ircpipe.Discovery
  alias Ircpipe.Irc.{Session, SessionLocator, SessionSupervisor}
  alias Ircpipe.IrcTestServer

  setup :register_and_log_in_user

  test "returns curated featured channels without requiring authentication" do
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

    conn = get(build_conn(), ~p"/api/discovery/featured_channels")

    assert %{"server_channels" => server_channels} = json_response(conn, 200)

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
    Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{user.id}")
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
