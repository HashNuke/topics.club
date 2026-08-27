defmodule Ircpipe.Irc.Session.JoinFlushTest do
  use Ircpipe.DataCase

  alias Ircpipe.AccountsFixtures
  alias Ircpipe.Chat.Connections
  alias Ircpipe.Irc.{Session, SessionSupervisor}
  alias Ircpipe.Irc.Session.JoinFlush
  alias Ircpipe.IrcTestServer
  alias Ircxd.Client.Info

  test "ignores stale tokens and current tokens while registration is incomplete" do
    current_token = make_ref()

    registered_state = %{
      registered?: true,
      join_flush_timer: {make_ref(), current_token},
      marker: :unchanged
    }

    assert JoinFlush.handle(registered_state, make_ref()) == {:noreply, registered_state}

    unregistered_state = %{registered_state | registered?: false}
    assert JoinFlush.handle(unregistered_state, current_token) == {:noreply, unregistered_state}
  end

  test "clears the current timer when the IRC client exits" do
    token = make_ref()

    state = %{
      client: nil,
      registered?: true,
      join_flush_timer: {make_ref(), token},
      marker: :preserved
    }

    assert {:noreply, returned} = JoinFlush.handle(state, token)
    assert returned.join_flush_timer == nil
    assert returned.marker == :preserved
  end

  test "refreshes client information and flushes a matching registered timer" do
    server = start_supervised!({IrcTestServer, self()})
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(user, %{
        "name" => "join flush",
        "host" => "localhost",
        "port" => IrcTestServer.port(server),
        "use_tls" => false,
        "nickname" => "ircpipe"
      })

    Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{user.id}")
    on_exit(fn -> SessionSupervisor.stop_session(connection) end)
    {:ok, _pid} = SessionSupervisor.start_session(connection)
    assert_receive {:buffer_system, %{body: "Connected to localhost."}}, 1_000

    token = make_ref()

    state =
      connection
      |> Session.via()
      |> :sys.get_state()
      |> Map.put(:join_validation_ready?, false)
      |> Map.put(:join_flush_timer, {make_ref(), token})

    assert {:noreply, returned} = JoinFlush.handle(state, token)
    assert %Info{} = returned.client_info
    assert returned.join_validation_ready?
    assert returned.joins_flushed?
    assert returned.join_flush_timer == nil

    assert :ok = Session.quit(connection)
  end
end
