defmodule IrcpipeWeb.Api.DiscoveryControllerTest do
  use IrcpipeWeb.ConnCase, async: false

  alias Ircpipe.Chat
  alias Ircpipe.Discovery
  alias Ircpipe.Irc.Session
  alias Ircpipe.IrcTestServer

  setup :register_and_log_in_user

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

    [server_channel] = Discovery.list_popular_server_channels()
    conn = post(conn, ~p"/api/discovery/server_channels/#{server_channel.id}/join")

    assert %{
             "connection" => %{
               "id" => connection_id,
               "host" => "127.0.0.1",
               "name" => "Local IRC"
             },
             "buffer" => %{
               "buffer_id" => "channel:" <> _,
               "title" => "#elixir"
             }
           } = json_response(conn, 202)

    assert_receive {:irc_server_line, "NICK " <> _nickname}, 1_000
    assert_receive {:irc_server_line, "USER " <> _rest}, 1_000
    assert_receive {:irc_server_line, "JOIN #elixir"}, 1_000

    connection = Chat.get_connection!(user, connection_id)
    assert connection.host == "127.0.0.1"
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
