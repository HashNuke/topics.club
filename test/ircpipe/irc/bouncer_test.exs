defmodule Ircpipe.Irc.BouncerTest do
  use Ircpipe.DataCase, async: false

  import ExUnit.CaptureLog

  alias Ircpipe.Accounts.User
  alias Ircpipe.AccountsFixtures
  alias Ircpipe.Chat
  alias Ircpipe.Irc.Bouncer
  alias Ircpipe.Irc.Session
  alias Ircpipe.Irc.SessionSupervisor
  alias Ircpipe.IrcTestServer
  alias Ircpipe.Repo

  test "starts sessions for users seen inside the idle window" do
    server = start_supervised!({IrcTestServer, self()})
    user = AccountsFixtures.user_fixture()
    mark_seen(user, DateTime.utc_now(:second))

    {:ok, connection} =
      Chat.create_connection(user, %{
        "name" => "local",
        "host" => "127.0.0.1",
        "port" => IrcTestServer.port(server),
        "use_tls" => false,
        "nickname" => "mira"
      })

    {:ok, _membership} = Chat.join_channel(user, connection, "#elixir")

    start_supervised!({Bouncer, enabled?: true, sweep_interval: :timer.hours(1), name: nil})

    assert_receive {:irc_server_line, "NICK mira"}, 1_000
    assert_receive {:irc_server_line, "USER mira 0 * mira"}, 1_000
    assert_receive {:irc_server_line, "JOIN #elixir"}, 1_000

    assert :ok = Session.quit(connection)
  end

  test "disconnects sessions after the idle window" do
    server = start_supervised!({IrcTestServer, self()})
    user = AccountsFixtures.user_fixture()
    mark_seen(user, DateTime.add(DateTime.utc_now(:second), -25, :hour))

    {:ok, connection} =
      Chat.create_connection(user, %{
        "name" => "local",
        "host" => "127.0.0.1",
        "port" => IrcTestServer.port(server),
        "use_tls" => false,
        "nickname" => "mira",
        "status" => "connected"
      })

    {:ok, _pid} = SessionSupervisor.start_session(connection)
    assert_receive {:irc_server_line, "NICK mira"}, 1_000
    assert_receive {:irc_server_line, "USER mira 0 * mira"}, 1_000

    pid = start_supervised!({Bouncer, enabled?: true, sweep_interval: :timer.hours(1), name: nil})
    send(pid, :sweep_inactive_sessions)
    _ = :sys.get_state(pid)

    assert_receive {:irc_server_line, "QUIT :idle timeout"}, 1_000
    assert Chat.get_connection!(user, connection.id).status == "disconnected"
  end

  test "stays disabled when configured off" do
    assert capture_log(fn ->
             pid = start_supervised!({Bouncer, enabled?: false, sweep_interval: 1, name: nil})
             send(pid, :start_recent_sessions)
             send(pid, :sweep_inactive_sessions)
           end) == ""
  end

  defp mark_seen(user, last_seen_at) do
    Repo.update_all(from(u in User, where: u.id == ^user.id), set: [last_seen_at: last_seen_at])
  end
end
