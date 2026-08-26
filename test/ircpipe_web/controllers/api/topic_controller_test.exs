defmodule IrcpipeWeb.Api.TopicControllerTest do
  use IrcpipeWeb.ConnCase, async: false

  alias Ircpipe.Chat.Connections
  alias Ircpipe.Chat.Topic
  alias Ircpipe.Irc.{Session, SessionSupervisor}
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
    topics = json_response(conn, 200)["topics"]

    assert Enum.any?(topics, &match?(%{"name" => "#elixir", "server_host" => "127.0.0.1"}, &1))
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
           } = json_response(conn, 202)

    assert topic_id == topic.id
    assert buffer_id == "channel:#{membership_id}"

    connection = Connections.get!(user, connection_id)
    expected_nick = user.email |> String.split("@") |> List.first()
    assert connection.nickname == expected_nick
    assert Enum.map(connection.channel_memberships, & &1.channel) == ["#elixir"]

    assert_receive {:irc_server_line, "JOIN #elixir"}, 2_000
    assert :ok = Session.quit(connection)
  end

  test "joining a suggested topic is idempotent", %{conn: conn, user: user} do
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

    on_exit(fn ->
      user
      |> Connections.list()
      |> Enum.each(&SessionSupervisor.stop_session/1)
    end)

    first = post(conn, ~p"/api/topics/#{topic.id}/join")
    second = post(conn, ~p"/api/topics/#{topic.id}/join")

    first_body = json_response(first, 202)
    second_body = json_response(second, 202)

    assert first_body["connection"]["id"] == second_body["connection"]["id"]

    assert first_body["buffer"]["channel_membership_id"] ==
             second_body["buffer"]["channel_membership_id"]

    connection = Connections.get!(user, first_body["connection"]["id"])
    assert :ok = SessionSupervisor.stop_session(connection)
  end
end
