defmodule Ircpipe.Engine.APITest do
  use Ircpipe.DataCase, async: false

  alias Ircpipe.AccountsFixtures
  alias Ircpipe.Chat.Connections
  alias Ircpipe.Chat.DirectMessageIngestion
  alias Ircpipe.Engine.API
  alias Ircpipe.Engine.LocalAdapter
  alias Ircpipe.EngineClient
  alias Ircpipe.EngineClient.Contract
  alias Ircpipe.Irc.SessionLocator
  alias Ircpipe.Irc.SessionSupervisor
  alias Ircpipe.IrcTestServer

  setup do
    previous_adapter = Application.get_env(:ircpipe, :engine_client_adapter)
    Application.put_env(:ircpipe, :engine_client_adapter, LocalAdapter)

    on_exit(fn ->
      if previous_adapter do
        Application.put_env(:ircpipe, :engine_client_adapter, previous_adapter)
      else
        Application.delete_env(:ircpipe, :engine_client_adapter)
      end
    end)

    user = AccountsFixtures.user_fixture()
    other_user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(user, %{
        "name" => "engine api",
        "host" => "irc.example.test",
        "port" => 6697,
        "use_tls" => true,
        "nickname" => "mira"
      })

    %{user: user, other_user: other_user, connection: connection}
  end

  test "unknown versions and operations return stable replies without crashing", %{user: user} do
    unsupported_version = %{
      version: 2,
      operation: :connection_info,
      request_id: "request-version",
      user_id: user.id,
      connection_id: 1,
      payload: %{}
    }

    assert %{
             status: :error,
             error: :unsupported_version,
             request_id: "request-version"
           } = API.dispatch(unsupported_version)

    unsupported_operation = %{unsupported_version | version: 1, operation: :unknown}

    assert %{status: :error, error: :unsupported_operation} =
             API.dispatch(unsupported_operation)

    assert %{status: :error, error: :invalid_request, operation: nil, request_id: nil} =
             API.dispatch(self())

    hostile_version = %{version: 2, operation: self(), request_id: self()}
    hostile_operation = %{version: 1, operation: self(), request_id: self()}

    for {hostile_request, expected_error} <- [
          {hostile_version, :unsupported_version},
          {hostile_operation, :unsupported_operation}
        ] do
      reply = API.dispatch(hostile_request)

      assert reply.error == expected_error
      assert reply.operation == nil
      assert reply.request_id == nil
      assert Contract.plain_term?(reply)
    end
  end

  test "the local adapter exercises the same envelope and returns plain status data", %{
    user: user,
    connection: connection
  } do
    assert {:ok, %{statuses: [%{connection_id: connection_id, status: "disconnected"}]}} =
             EngineClient.connection_statuses(user.id, [connection.id],
               request_id: "request-status"
             )

    assert connection_id == connection.id
  end

  test "every operation reauthorizes the connection inside the engine API", %{
    other_user: other_user,
    connection: connection
  } do
    requests = [
      {:connection_statuses, nil, %{connection_ids: [connection.id]}},
      {:connection_info, connection.id, %{}},
      {:ensure_connection, connection.id, %{intent: "restore"}},
      {:disconnect_connection, connection.id, %{}},
      {:quiesce_connection, connection.id, %{}},
      {:join_channel, connection.id, %{channel: "#elixir"}},
      {:part_channel, connection.id, %{membership_id: 1}},
      {:send_channel_message, connection.id, %{membership_id: 1, body: "hello", kind: "message"}},
      {:send_direct_message, connection.id, %{thread_id: 1, body: "hello"}},
      {:execute_command, connection.id,
       %{line: "NICK mira_", command_id: "command-1", buffer_id: "server:#{connection.id}"}},
      {:list_channels, connection.id, %{}}
    ]

    for {operation, connection_id, payload} <- requests do
      assert {:ok, request} =
               Contract.new(operation, other_user.id, connection_id, payload,
                 request_id: "request-#{operation}"
               )

      assert %{status: :error, error: :unauthorized} = API.dispatch(request)
    end
  end

  test "connection information normalizes a missing local session", %{
    user: user,
    connection: connection
  } do
    assert {:error, %{code: :not_connected, details: %{}}} =
             EngineClient.connection_info(user.id, connection.id)
  end

  test "an empty status batch still reauthorizes the user" do
    assert {:error, %{code: :unauthorized}} =
             EngineClient.connection_statuses(9_223_372_036_854_775_000, [])
  end

  test "restore mode respects paused durable intent", %{user: user, connection: connection} do
    assert {:ok, paused} = Connections.request_disconnect(user, connection.id)
    assert paused.desired_state == "paused"

    assert {:error, %{code: :invalid_state, details: %{reason: "connection_paused"}}} =
             EngineClient.ensure_connection(user.id, connection.id, intent: "restore")
  end

  test "opposing connection intents serialize through their process effects", %{
    user: user,
    connection: connection
  } do
    server = start_supervised!({IrcTestServer, self()})

    {:ok, connection} =
      connection
      |> Ecto.Changeset.change(
        host: "localhost",
        port: IrcTestServer.port(server),
        use_tls: false
      )
      |> Repo.update()

    assert {:ok, %{status: status}} =
             EngineClient.ensure_connection(user.id, connection.id, intent: "active")

    assert status in ["connecting", "connected"]
    session_pid = SessionLocator.whereis(connection)
    assert is_pid(session_pid)

    replacement_server =
      start_supervised!(%{
        id: :replacement_irc_test_server,
        start: {IrcTestServer, :start_link, [self()]}
      })

    {:ok, connection} =
      connection
      |> Ecto.Changeset.change(port: IrcTestServer.port(replacement_server))
      |> Repo.update()

    previous_pause = Application.get_env(:ircpipe, :pause_session_stop_after_lookup)
    Application.put_env(:ircpipe, :pause_session_stop_after_lookup, self())

    on_exit(fn ->
      Application.delete_env(:ircpipe, :pause_session_stop_after_lookup)
      _ = SessionSupervisor.stop_session(connection)

      if previous_pause do
        Application.put_env(:ircpipe, :pause_session_stop_after_lookup, previous_pause)
      else
        Application.delete_env(:ircpipe, :pause_session_stop_after_lookup)
      end
    end)

    task_supervisor = start_supervised!(Task.Supervisor)

    disconnect_task =
      Task.Supervisor.async_nolink(task_supervisor, fn ->
        EngineClient.disconnect_connection(user.id, connection.id)
      end)

    assert_receive {:session_stop_paused, stop_pid, ^session_pid}

    ensure_task =
      Task.Supervisor.async_nolink(task_supervisor, fn ->
        EngineClient.ensure_connection(user.id, connection.id, intent: "active")
      end)

    refute Task.yield(ensure_task, 100)
    Application.delete_env(:ircpipe, :pause_session_stop_after_lookup)
    send(stop_pid, {:continue_session_stop, session_pid})

    assert {:ok, %{connection: %{desired_state: "paused"}, status: "disconnected"}} =
             Task.await(disconnect_task)

    assert {:ok, %{connection: %{desired_state: "connected"}, status: restored_status}} =
             Task.await(ensure_task)

    assert restored_status in ["connecting", "connected"]
    assert Repo.get!(Ircpipe.Chat.ServerConnection, connection.id).desired_state == "connected"
    assert is_pid(SessionLocator.whereis(connection))

    assert {:ok, %{status: "disconnected"}} =
             EngineClient.disconnect_connection(user.id, connection.id)
  end

  test "malformed requests never reach operation dispatch", %{user: user, connection: connection} do
    assert {:error, %{code: :invalid_request}} =
             EngineClient.request(
               :join_channel,
               user.id,
               connection.id,
               %{channel: self()}
             )
  end

  test "the local adapter executes the initial live operation set with plain replies", %{
    user: user
  } do
    server = start_supervised!({IrcTestServer, self()})

    {:ok, connection} =
      Connections.create(user, %{
        "name" => "engine api live",
        "host" => "localhost",
        "port" => IrcTestServer.port(server),
        "use_tls" => false,
        "nickname" => "ircpipe"
      })

    Phoenix.PubSub.subscribe(Ircpipe.PubSub, "user:#{user.id}")

    assert {:ok, %{membership: membership, status: status}} =
             EngineClient.join_channel(user.id, connection.id, "#pipe")

    assert status in ["queued", "sent"]
    assert membership.channel == "#pipe"
    assert is_integer(membership.id)
    assert_receive {:irc_server_line, "NICK ircpipe"}, 1_000
    assert_receive {:irc_server_line, "USER ircpipe 0 * ircpipe"}, 1_000
    assert_receive {:irc_server_line, "JOIN #pipe"}, 1_000
    assert_receive {:presence_sync, %{buffer_id: "channel:" <> _}}, 1_000

    assert {:ok, %{connection_info: %{registered?: true, casemapping: :rfc1459}}} =
             EngineClient.connection_info(user.id, connection.id)

    assert {:ok, %{message: channel_message}} =
             EngineClient.send_channel_message(
               user.id,
               connection.id,
               membership.id,
               "hello from engine client"
             )

    assert channel_message.body == "hello from engine client"
    assert is_binary(channel_message.occurred_at)
    assert_receive {:irc_server_line, "PRIVMSG #pipe :hello from engine client"}, 1_000

    assert {:ok, %{channels: [%{channel: "#elixir"} | _channels]}} =
             EngineClient.list_channels(user.id, connection.id)

    assert_receive {:irc_server_line, "LIST"}, 1_000

    assert {:ok, %{result: command_result}} =
             EngineClient.execute_command(
               user.id,
               connection.id,
               "NICK ircpipe_",
               "command-api-1",
               "server:#{connection.id}"
             )

    assert command_result.command == "nick"
    assert command_result.command_id == "command-api-1"
    assert_receive {:irc_server_line, "NICK ircpipe_"}, 1_000

    assert {:ok, %{thread: thread}} =
             DirectMessageIngestion.record(
               connection,
               "akash",
               "akash",
               "hello",
               "message",
               %{direction: "outgoing"}
             )

    assert {:ok, %{thread: sent_thread, message: direct_message}} =
             EngineClient.send_direct_message(
               user.id,
               connection.id,
               thread.id,
               "private hello"
             )

    assert sent_thread.id == thread.id
    assert direct_message.body == "private hello"
    assert_receive {:irc_server_line, "PRIVMSG akash :private hello"}, 1_000

    assert {:ok, %{membership_id: membership_id, status: "sent"}} =
             EngineClient.part_channel(user.id, connection.id, membership.id)

    assert membership_id == membership.id
    assert_receive {:irc_server_line, "PART #pipe" <> _reason}, 1_000

    assert {:ok, %{connection: %{desired_state: "paused"}, status: "disconnected"}} =
             EngineClient.disconnect_connection(user.id, connection.id)

    assert_receive {:irc_server_line, "QUIT leaving"}, 1_000

    assert {:ok, %{quiesced: true}} =
             EngineClient.quiesce_connection(user.id, connection.id)
  end
end
