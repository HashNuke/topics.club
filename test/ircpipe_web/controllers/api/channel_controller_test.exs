defmodule IrcpipeWeb.Api.ChannelControllerTest do
  use IrcpipeWeb.ConnCase, async: false

  alias Ircpipe.Chat
  alias Ircpipe.Chat.Connections
  alias Ircpipe.Chat.ChannelMembership
  alias Ircpipe.Chat.MembershipLookup
  alias Ircpipe.Irc.SessionSupervisor
  alias Ircpipe.IrcTestServer
  alias Ircpipe.Repo

  setup :register_and_log_in_user

  test "rejects multi-target HTTP joins before persistence or transmission", %{
    conn: conn,
    user: user
  } do
    server = start_supervised!({IrcTestServer, self()})

    {:ok, connection} =
      Connections.create(user, %{
        "name" => "join-policy",
        "host" => "127.0.0.1",
        "port" => IrcTestServer.port(server),
        "use_tls" => false,
        "nickname" => "mira"
      })

    conn = post(conn, ~p"/api/connections/#{connection.id}/channels", %{channel: "#a,#b"})

    assert %{"error" => "invalid_arguments"} = json_response(conn, 422)
    assert Repo.all(ChannelMembership) == []
    refute_receive {:irc_server_line, "JOIN #a,#b"}
  end

  test "marks a channel membership read through the API", %{conn: conn, user: user} do
    {:ok, connection} =
      Connections.create(user, %{
        "name" => "local",
        "host" => "127.0.0.1",
        "port" => 6667,
        "use_tls" => false,
        "nickname" => "mira"
      })

    {:ok, membership} = Chat.join_channel(user, connection, "#elixir")

    membership =
      membership |> Ecto.Changeset.change(unread_count: 3, mention_count: 1) |> Repo.update!()

    conn = post(conn, ~p"/api/channels/#{membership.id}/read")

    assert json_response(conn, 200) == %{"ok" => true}

    reloaded = MembershipLookup.get!(user, membership.id)
    assert reloaded.unread_count == 0
    assert reloaded.mention_count == 0
  end

  test "returns a conflict when marking a channel read during connection deletion", %{
    conn: conn,
    user: user
  } do
    {:ok, connection} =
      Connections.create(user, %{
        "name" => "deleting",
        "host" => "127.0.0.1",
        "port" => 6667,
        "use_tls" => false,
        "nickname" => "mira"
      })

    {:ok, membership} = Chat.join_channel(user, connection, "#elixir")

    connection
    |> Ecto.Changeset.change(deleting: true)
    |> Repo.update!()

    conn = post(conn, ~p"/api/channels/#{membership.id}/read")

    assert json_response(conn, 409) == %{"error" => "connection_deleting"}
  end

  test "leaves a channel membership through the API", %{conn: conn, user: user} do
    server = start_supervised!({IrcTestServer, self()})

    {:ok, connection} =
      Connections.create(user, %{
        "name" => "local",
        "host" => "127.0.0.1",
        "port" => IrcTestServer.port(server),
        "use_tls" => false,
        "nickname" => "mira"
      })

    {:ok, membership} = Chat.join_channel(user, connection, "#elixir")
    Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{user.id}")
    {:ok, _pid} = SessionSupervisor.start_session(connection)

    assert_receive {:buffer_system, %{body: "Connected to 127.0.0.1."}}, 1_000
    assert_receive {:irc_server_line, "JOIN #elixir"}, 1_000

    conn = post(conn, ~p"/api/channel_memberships/#{membership.id}/leave")

    assert %{"status" => "sent", "buffer_id" => buffer_id} = json_response(conn, 200)

    assert buffer_id == "channel:#{membership.id}"
    assert_receive {:irc_server_line, "PART #elixir :"}, 1_000

    assert_receive {:buffer_left,
                    %{
                      type: "buffer:left",
                      buffer_id: ^buffer_id,
                      channel_membership_id: membership_id
                    }},
                   1_000

    assert membership_id == membership.id
    assert MembershipLookup.get!(user, membership.id).status == "left"
    assert :ok = Ircpipe.Irc.Session.quit(connection)
  end

  test "does not leave another user's channel membership", %{conn: conn} do
    other_user = Ircpipe.AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(other_user, %{
        "name" => "local",
        "host" => "127.0.0.1",
        "port" => 6667,
        "use_tls" => false,
        "nickname" => "other"
      })

    {:ok, membership} = Chat.join_channel(other_user, connection, "#private")

    assert_error_sent 404, fn ->
      post(conn, ~p"/api/channel_memberships/#{membership.id}/leave")
    end
  end
end
