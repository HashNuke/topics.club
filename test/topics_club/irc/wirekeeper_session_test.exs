defmodule TopicsClub.Irc.WirekeeperSessionTest do
  use TopicsClub.DataCase, async: false

  alias TopicsClub.AccountsFixtures
  alias TopicsClub.Chat
  alias TopicsClub.Chat.{Connections, MessageHistory}
  alias TopicsClub.Irc.{Session, SessionSupervisor}
  alias TopicsClub.IrcTestServer
  alias TopicsClub.Wirekeeper

  setup do
    previous = Application.get_env(:topics_club_engine, :irc_transport)
    previous_retry_delay = Application.get_env(:topics_club_engine, :session_retry_delay_ms)
    Application.put_env(:topics_club_engine, :irc_transport, {:wirekeeper, node()})

    on_exit(fn ->
      restore_transport(previous)
      restore_retry_delay(previous_retry_delay)
    end)
  end

  test "an engine Session resumes buffered IRC traffic without repeating connection setup" do
    server = start_supervised!({IrcTestServer, {self(), accept_reconnects?: true}})
    {user, connection} = connection_fixture(server, "wirekeeper resume")
    {:ok, membership} = Chat.join_channel(user, connection, "#pipe")
    Phoenix.PubSub.subscribe(TopicsClub.PubSub, "user:#{user.id}")
    close_on_exit(connection)

    assert {:ok, first_session} = SessionSupervisor.start_session(connection)
    assert_receive {:irc_server_line, "NICK topics_club"}, 1_000
    assert_receive {:irc_server_line, "USER topics_club 0 * topics_club"}, 1_000
    assert_receive {:irc_server_line, "JOIN #pipe"}, 1_000

    assert :ok = IrcTestServer.broadcast(server, "#pipe", "akash", "before restart")
    assert_receive {:buffer_message, %{body: "before restart"}}, 1_000

    assert Enum.any?(
             MessageHistory.list_messages(user, membership.id),
             &(&1.body == "before restart")
           )

    assert_eventually(fn ->
      match?({:ok, %{buffered_records: 0, attached?: true}}, Wirekeeper.info(connection.id))
    end)

    assert :ok = SessionSupervisor.stop_for_restart(connection)

    first_session_ref = Process.monitor(first_session)
    assert_receive {:DOWN, ^first_session_ref, :process, ^first_session, _reason}, 1_000

    assert_eventually(fn ->
      match?({:ok, %{attached?: false}}, Wirekeeper.info(connection.id))
    end)

    assert :ok = IrcTestServer.broadcast(server, "#pipe", "mira", "while engine was down")

    assert_eventually(fn ->
      match?({:ok, %{buffered_records: count}} when count > 0, Wirekeeper.info(connection.id))
    end)

    flush_server_lines()
    assert {:ok, resumed_session} = SessionSupervisor.start_session(connection)
    resumed_ref = Process.monitor(resumed_session)

    refute_receive {:DOWN, ^resumed_ref, :process, ^resumed_session, reason},
                   200,
                   "resumed Session stopped: #{inspect(reason)}"

    assert_receive {:buffer_message, %{body: "while engine was down"}}, 1_000

    state = :sys.get_state(resumed_session)
    assert state.resumed?
    assert MapSet.member?(state.joined_channels, "#pipe")

    refute_connection_setup_lines()

    assert Enum.any?(
             MessageHistory.list_messages(user, membership.id),
             &(&1.body == "while engine was down")
           )

    assert_eventually(fn ->
      match?({:ok, %{buffered_records: 0, attached?: true}}, Wirekeeper.info(connection.id))
    end)

    assert {:ok, _message} = Session.say(connection, "#pipe", "after restart")
    assert_receive {:irc_server_line, "PRIVMSG #pipe :after restart"}, 1_000
  end

  test "the authoritative deletion stop closes its retained Wirekeeper generation" do
    server = start_supervised!({IrcTestServer, self()})
    {user, connection} = connection_fixture(server, "wirekeeper deletion")
    close_on_exit(connection)
    Phoenix.PubSub.subscribe(TopicsClub.PubSub, "user:#{user.id}")

    assert {:ok, session} = SessionSupervisor.start_session(connection)
    assert_receive {:irc_server_line, "NICK topics_club"}, 1_000
    assert_receive {:server_status, %{status: "connected"}}, 1_000
    _state = :sys.get_state(session)

    assert_eventually(fn ->
      match?(
        {:ok, %{status: :open, buffered_records: 0}},
        Wirekeeper.info(connection.id)
      )
    end)

    assert :ok = SessionSupervisor.stop_for_deletion(connection)
    assert_eventually(fn -> Wirekeeper.info(connection.id) == {:error, :not_found} end)
  end

  test "an abrupt Ircxd client crash detaches and replays through the same Session" do
    Application.put_env(:topics_club_engine, :session_retry_delay_ms, 500)
    server = start_supervised!({IrcTestServer, {self(), accept_reconnects?: true}})
    {user, connection} = connection_fixture(server, "wirekeeper client crash")
    {:ok, membership} = Chat.join_channel(user, connection, "#pipe")
    Phoenix.PubSub.subscribe(TopicsClub.PubSub, "user:#{user.id}")
    close_on_exit(connection)

    assert {:ok, session} = SessionSupervisor.start_session(connection)
    assert_receive {:irc_server_line, "NICK topics_club"}, 1_000
    assert_receive {:irc_server_line, "USER topics_club 0 * topics_club"}, 1_000
    assert_receive {:irc_server_line, "JOIN #pipe"}, 1_000

    assert_eventually(fn ->
      match?({:ok, %{buffered_records: 0, attached?: true}}, Wirekeeper.info(connection.id))
    end)

    assert [{client, nil}] =
             Registry.lookup(
               TopicsClub.Irc.ClientRegistry,
               {connection.user_id, connection.id}
             )

    client_ref = Process.monitor(client)
    Process.exit(client, :kill)
    assert_receive {:DOWN, ^client_ref, :process, ^client, :killed}, 1_000

    assert_eventually(fn ->
      match?({:ok, %{attached?: false}}, Wirekeeper.info(connection.id))
    end)

    assert :ok = IrcTestServer.broadcast(server, "#pipe", "akash", "during client retry")

    assert_eventually(fn ->
      match?({:ok, %{buffered_records: count}} when count > 0, Wirekeeper.info(connection.id))
    end)

    flush_server_lines()
    assert_receive {:buffer_message, %{body: "during client retry"}}, 2_000
    assert session == TopicsClub.Irc.SessionLocator.whereis(connection)
    refute_connection_setup_lines()

    assert Enum.any?(
             MessageHistory.list_messages(user, membership.id),
             &(&1.body == "during client retry")
           )
  end

  test "a prolonged Wirekeeper outage consumes bounded retries without restarting the Session" do
    Application.put_env(:topics_club_engine, :session_retry_delay_ms, 200)
    server = start_supervised!({IrcTestServer, self()})
    {_user, connection} = connection_fixture(server, "wirekeeper prolonged outage")
    close_on_exit(connection)

    assert {:ok, session} = SessionSupervisor.start_session(connection)
    assert_receive {:irc_server_line, "NICK topics_club"}, 1_000
    assert_receive {:irc_server_line, "USER topics_club 0 * topics_club"}, 1_000

    assert_eventually(fn ->
      match?(
        {:ok, %{attached?: true, buffered_records: 0}},
        Wirekeeper.info(connection.id)
      )
    end)

    assert [{client, nil}] =
             Registry.lookup(
               TopicsClub.Irc.ClientRegistry,
               {connection.user_id, connection.id}
             )

    Application.put_env(
      :topics_club_engine,
      :irc_transport,
      {:wirekeeper, :missing_wirekeeper@localhost}
    )

    send(client, {:nodedown, node()})

    assert_eventually(fn ->
      state = :sys.get_state(session)
      state.retry_attempt >= 2 and state.wirekeeper_node_down?
    end)

    assert SessionSupervisor.start_session(connection) == {:ok, session}

    Application.put_env(:topics_club_engine, :irc_transport, {:wirekeeper, node()})

    assert_eventually(fn ->
      state = :sys.get_state(session)
      state.retry_attempt == 0 and state.registered?
    end)
  end

  defp connection_fixture(server, name) do
    user = AccountsFixtures.user_fixture()

    assert {:ok, connection} =
             Connections.create(user, %{
               "name" => name,
               "host" => "127.0.0.1",
               "port" => IrcTestServer.port(server),
               "use_tls" => false,
               "nickname" => "topics_club"
             })

    {user, connection}
  end

  defp close_on_exit(connection) do
    on_exit(fn ->
      _result = SessionSupervisor.stop_for_deletion(connection)
    end)
  end

  defp assert_eventually(callback, attempts \\ 1_000)

  defp assert_eventually(callback, attempts) when attempts > 0 do
    if callback.() do
      :ok
    else
      receive do
      after
        2 -> assert_eventually(callback, attempts - 1)
      end
    end
  end

  defp assert_eventually(_callback, 0), do: flunk("condition did not become true")

  defp flush_server_lines do
    receive do
      {:irc_server_line, _line} -> flush_server_lines()
    after
      0 -> :ok
    end
  end

  defp refute_connection_setup_lines do
    receive do
      {:irc_server_line, line} ->
        refute String.starts_with?(line, [
                 "PASS ",
                 "CAP ",
                 "AUTHENTICATE ",
                 "NICK ",
                 "USER ",
                 "JOIN "
               ])

        refute_connection_setup_lines()
    after
      200 -> :ok
    end
  end

  defp restore_transport(nil), do: Application.delete_env(:topics_club_engine, :irc_transport)

  defp restore_transport(previous),
    do: Application.put_env(:topics_club_engine, :irc_transport, previous)

  defp restore_retry_delay(nil),
    do: Application.delete_env(:topics_club_engine, :session_retry_delay_ms)

  defp restore_retry_delay(previous),
    do: Application.put_env(:topics_club_engine, :session_retry_delay_ms, previous)
end
