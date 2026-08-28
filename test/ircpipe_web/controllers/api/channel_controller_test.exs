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

  test "returns service unavailable for unavailable and timed-out engine joins", %{
    user: user
  } do
    {:ok, connection} =
      Connections.create(user, %{
        "name" => "degraded",
        "host" => "127.0.0.1",
        "port" => 6667,
        "use_tls" => false,
        "nickname" => "mira"
      })

    configure_engine_test_adapter()

    for code <- [:not_connected, :engine_unavailable, :timeout] do
      Application.put_env(:ircpipe_core, :engine_client_test_reply, {:error, code})

      response =
        build_conn()
        |> log_in_user(user)
        |> post(~p"/api/connections/#{connection.id}/channels", %{channel: "#elixir"})

      assert %{"error" => error} = json_response(response, 503)
      assert error == Atom.to_string(code)
    end
  end

  test "retains the concrete engine reason for an invalid-state join", %{user: user} do
    {:ok, connection} =
      Connections.create(user, %{
        "name" => "pending",
        "host" => "127.0.0.1",
        "port" => 6667,
        "use_tls" => false,
        "nickname" => "mira"
      })

    configure_engine_test_adapter()

    Application.put_env(
      :ircpipe_core,
      :engine_client_test_reply,
      {:error, :invalid_state, %{reason: "already_pending"}}
    )

    response =
      build_conn()
      |> log_in_user(user)
      |> post(~p"/api/connections/#{connection.id}/channels", %{channel: "#elixir"})

    assert %{"error" => "already_pending"} = json_response(response, 422)
  end

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

  defp configure_engine_test_adapter do
    previous_adapter = Application.get_env(:ircpipe_core, :engine_client_adapter)
    previous_test_pid = Application.get_env(:ircpipe_core, :engine_client_test_pid)
    previous_test_reply = Application.get_env(:ircpipe_core, :engine_client_test_reply)

    Application.put_env(:ircpipe_core, :engine_client_adapter, Ircpipe.EngineClientTestAdapter)
    Application.put_env(:ircpipe_core, :engine_client_test_pid, self())

    on_exit(fn ->
      restore_env(:engine_client_adapter, previous_adapter)
      restore_env(:engine_client_test_pid, previous_test_pid)
      restore_env(:engine_client_test_reply, previous_test_reply)
    end)
  end

  defp restore_env(key, nil), do: Application.delete_env(:ircpipe_core, key)
  defp restore_env(key, value), do: Application.put_env(:ircpipe_core, key, value)
end
