defmodule IrcpipeWeb.Api.TopicControllerTest do
  use IrcpipeWeb.ConnCase, async: true

  alias Ircpipe.Chat
  alias Ircpipe.Chat.Topic
  alias Ircpipe.Irc.Session
  alias Ircpipe.IrcTestServer
  alias Ircpipe.Repo

  setup :register_and_log_in_user

  test "lists suggested local topics", %{conn: conn} do
    Repo.insert!(
      Topic.changeset(%Topic{}, %{
        name: "#elixir",
        description: "Local Elixir discussion.",
        server_host: "127.0.0.1",
        server_port: 6667,
        use_tls: false,
        channel: "#elixir",
        sort_order: 10
      })
    )

    conn = get(conn, ~p"/api/topics")

    assert %{"topics" => [%{"name" => "#elixir", "server_host" => "127.0.0.1"}]} =
             json_response(conn, 200)
  end

  test "joins a suggested topic using the local IRC server", %{conn: conn, user: user} do
    server = start_supervised!({IrcTestServer, self()})

    topic =
      Repo.insert!(
        Topic.changeset(%Topic{}, %{
          name: "#elixir",
          description: "Local Elixir discussion.",
          server_host: "127.0.0.1",
          server_port: IrcTestServer.port(server),
          use_tls: false,
          channel: "#elixir",
          sort_order: 10
        })
      )

    conn = post(conn, ~p"/api/topics/#{topic.id}/join")

    assert %{
             "topic" => %{"id" => topic_id, "server_host" => "127.0.0.1"},
             "connection" => %{"id" => connection_id, "host" => "127.0.0.1"},
             "buffer" => %{
               "buffer_id" => buffer_id,
               "buffer_type" => "channel",
               "channel_membership_id" => membership_id,
               "title" => "#elixir"
             }
           } = json_response(conn, 200)

    assert topic_id == topic.id
    assert buffer_id == "channel:#{membership_id}"

    connection = Chat.get_connection!(user, connection_id)
    expected_nick = user.email |> String.split("@") |> List.first()
    assert connection.nickname == expected_nick
    assert Enum.map(connection.channel_memberships, & &1.channel) == ["#elixir"]

    assert_receive {:irc_server_line, "JOIN #elixir"}, 1_000
    assert :ok = Session.quit(connection)
  end

  test "joining a suggested topic is idempotent", %{conn: conn} do
    topic =
      Repo.insert!(
        Topic.changeset(%Topic{}, %{
          name: "#phoenix",
          description: "Local Phoenix discussion.",
          server_host: "127.0.0.1",
          server_port: 6667,
          use_tls: false,
          channel: "#phoenix",
          sort_order: 20
        })
      )

    first = post(conn, ~p"/api/topics/#{topic.id}/join")
    second = post(conn, ~p"/api/topics/#{topic.id}/join")

    first_body = json_response(first, 200)
    second_body = json_response(second, 200)

    assert first_body["connection"]["id"] == second_body["connection"]["id"]

    assert first_body["buffer"]["channel_membership_id"] ==
             second_body["buffer"]["channel_membership_id"]
  end
end
