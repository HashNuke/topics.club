defmodule TopicsClub.EngineRestartTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  alias TopicsClub.Accounts.User
  alias TopicsClub.AccountsFixtures
  alias TopicsClub.Chat
  alias TopicsClub.Chat.Connections
  alias TopicsClub.EngineClient
  alias TopicsClub.EngineClient.Discovery
  alias TopicsClub.Irc.Bouncer
  alias TopicsClub.Irc.SessionLocator
  alias TopicsClub.Irc.SessionSupervisor
  alias TopicsClub.IrcTestServer
  alias TopicsClub.Repo

  setup do
    previous_bouncer_setting = Application.fetch_env!(:topics_club_engine, :irc_bouncer_enabled)
    :ok = Ecto.Adapters.SQL.Sandbox.mode(Repo, :auto)
    user = AccountsFixtures.user_fixture()

    on_exit(fn ->
      capture_log(fn ->
        if :topics_club_engine in started_applications() do
          :ok = Application.stop(:topics_club_engine)
        end

        Repo.delete_all(from(account in User, where: account.id == ^user.id))
        Application.put_env(:topics_club_engine, :irc_bouncer_enabled, previous_bouncer_setting)
        assert {:ok, _applications} = Application.ensure_all_started(:topics_club_engine)
        :ok = Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual)
      end)
    end)

    %{user: user}
  end

  test "an engine restart restores recent connected sessions and their autojoins only", %{
    user: user
  } do
    capture_log(fn -> exercise_engine_restart(user) end)
  end

  defp exercise_engine_restart(user) do
    server = start_supervised!({IrcTestServer, {self(), accept_reconnects?: true}})

    Repo.update_all(
      from(account in User, where: account.id == ^user.id),
      set: [last_seen_at: DateTime.utc_now(:second)]
    )

    connected = connection_fixture(user, server, "restored", "restored_nick")
    paused = connection_fixture(user, server, "paused", "paused_nick")
    assert {:ok, _membership} = Chat.join_channel(user, connected, "#restored")

    assert {:ok, paused} =
             paused
             |> Ecto.Changeset.change(desired_state: "paused")
             |> Repo.update()

    assert {:ok, old_session} = SessionSupervisor.start_session(connected)
    old_marker = elem(Discovery.whereis(), 1)

    assert_receive {:irc_server_line, "NICK restored_nick"}, 1_000
    assert_receive {:irc_server_line, "USER restored_nick 0 * restored_nick"}, 1_000
    assert_receive {:irc_server_line, "JOIN #restored"}, 1_000

    session_ref = Process.monitor(old_session)
    marker_ref = Process.monitor(old_marker)
    gateway = Process.whereis(TopicsClubWeb.Supervisor)
    core = Process.whereis(TopicsClub.CoreSupervisor)
    assert is_pid(gateway)
    assert is_pid(core)
    gateway_ref = Process.monitor(gateway)
    core_ref = Process.monitor(core)

    Application.put_env(:topics_club_engine, :irc_bouncer_enabled, true)
    assert :ok = Application.stop(:topics_club_engine)

    assert_receive {:DOWN, ^session_ref, :process, ^old_session, _reason}
    assert_receive {:DOWN, ^marker_ref, :process, ^old_marker, _reason}
    refute_receive {:DOWN, ^gateway_ref, :process, ^gateway, _reason}, 100
    refute_receive {:DOWN, ^core_ref, :process, ^core, _reason}, 100
    assert Repo.get!(TopicsClub.Chat.ServerConnection, connected.id).desired_state == "connected"

    assert {:error, %{code: :engine_unavailable}} =
             EngineClient.ensure_connection(user.id, connected.id, timeout: 100)

    assert {:ok, _applications} = Application.ensure_all_started(:topics_club_engine)
    _ = :sys.get_state(Bouncer)

    assert_receive {:irc_server_line, "NICK restored_nick"}, 1_000
    assert_receive {:irc_server_line, "USER restored_nick 0 * restored_nick"}, 1_000
    assert_receive {:irc_server_line, "JOIN #restored"}, 1_000

    restored_session = SessionLocator.whereis(connected)
    assert is_pid(restored_session)
    refute restored_session == old_session
    refute elem(Discovery.whereis(), 1) == old_marker
    assert SessionLocator.whereis(paused) == nil
    refute_receive {:irc_server_line, "NICK paused_nick"}
    assert DynamicSupervisor.count_children(SessionSupervisor).active == 1
  end

  defp connection_fixture(user, server, name, nickname) do
    assert {:ok, connection} =
             Connections.create(user, %{
               "name" => name,
               "host" => "localhost",
               "port" => IrcTestServer.port(server),
               "use_tls" => false,
               "nickname" => nickname
             })

    connection
  end

  defp started_applications do
    Application.started_applications()
    |> Enum.map(&elem(&1, 0))
  end
end
