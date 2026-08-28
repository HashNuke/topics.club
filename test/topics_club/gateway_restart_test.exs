defmodule TopicsClub.GatewayRestartTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import ExUnit.CaptureLog
  import Phoenix.ConnTest

  @endpoint TopicsClubWeb.Endpoint

  alias TopicsClub.Accounts.User
  alias TopicsClub.AccountsFixtures
  alias TopicsClub.Chat
  alias TopicsClub.Chat.Connections
  alias TopicsClub.Irc.SessionLocator
  alias TopicsClub.Irc.SessionSupervisor
  alias TopicsClub.IrcTestServer
  alias TopicsClub.Repo
  alias TopicsClubWeb.ConnCase

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.mode(Repo, :auto)
    user = AccountsFixtures.user_fixture()

    on_exit(fn ->
      capture_log(fn ->
        if :topics_club_gateway in started_applications() do
          :ok = Application.stop(:topics_club_gateway)
        end

        Enum.each(Connections.list(user), &SessionSupervisor.stop_session/1)
        Repo.delete_all(from(account in User, where: account.id == ^user.id))
        assert {:ok, _applications} = Application.ensure_all_started(:topics_club_gateway)
        :ok = Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual)
      end)
    end)

    %{user: user}
  end

  test "a gateway restart recovers messages received while its application was down", %{
    user: user
  } do
    capture_log(fn -> exercise_gateway_restart(user) end)
  end

  defp exercise_gateway_restart(user) do
    server = start_supervised!({IrcTestServer, self()})

    assert {:ok, connection} =
             Connections.create(user, %{
               "name" => "gateway restart",
               "host" => "localhost",
               "port" => IrcTestServer.port(server),
               "use_tls" => false,
               "nickname" => "gateway_nick"
             })

    assert {:ok, membership} = Chat.join_channel(user, connection, "#gateway-restart")
    assert {:ok, session} = SessionSupervisor.start_session(connection)

    assert_receive {:irc_server_line, "NICK gateway_nick"}, 1_000
    assert_receive {:irc_server_line, "USER gateway_nick 0 * gateway_nick"}, 1_000
    assert_receive {:irc_server_line, "JOIN #gateway-restart"}, 1_000

    :ok = Phoenix.PubSub.subscribe(TopicsClub.PubSub, "user:#{user.id}")

    gateway = Process.whereis(TopicsClubWeb.Supervisor)
    engine = Process.whereis(TopicsClub.EngineSupervisor)
    marker = elem(TopicsClub.EngineClient.Discovery.whereis(), 1)
    assert is_pid(gateway)
    assert is_pid(engine)

    gateway_ref = Process.monitor(gateway)
    session_ref = Process.monitor(session)
    engine_ref = Process.monitor(engine)
    marker_ref = Process.monitor(marker)

    assert :ok = Application.stop(:topics_club_gateway)
    assert_receive {:DOWN, ^gateway_ref, :process, ^gateway, _reason}
    refute_receive {:DOWN, ^session_ref, :process, ^session, _reason}, 100
    refute_receive {:DOWN, ^engine_ref, :process, ^engine, _reason}, 100
    refute_receive {:DOWN, ^marker_ref, :process, ^marker, _reason}, 100

    assert :ok =
             IrcTestServer.broadcast(
               server,
               "#gateway-restart",
               "akash",
               "persisted during gateway restart"
             )

    assert_receive {:buffer_message, %{body: "persisted during gateway restart"}}, 1_000

    assert {:ok, _applications} = Application.ensure_all_started(:topics_club_gateway)
    refute Process.whereis(TopicsClubWeb.Supervisor) == gateway
    assert SessionLocator.whereis(connection) == session

    conn = build_conn() |> ConnCase.log_in_user(user) |> get("/api/bootstrap")
    payload = json_response(conn, 200)
    messages = get_in(payload, ["messages_by_buffer", "channel:#{membership.id}"])

    assert Enum.any?(messages, &(&1["body"] == "persisted during gateway restart"))
    assert SessionLocator.whereis(connection) == session
  end

  defp started_applications do
    Application.started_applications()
    |> Enum.map(&elem(&1, 0))
  end
end
