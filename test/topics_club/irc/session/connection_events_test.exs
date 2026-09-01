defmodule TopicsClub.Irc.Session.ConnectionEventsTest do
  use TopicsClub.DataCase, async: true

  alias TopicsClub.AccountsFixtures

  alias TopicsClub.Chat.{
    ChannelMembership,
    CommandMessages,
    Connections,
    Message,
    MessageHistory,
    ServerConnection
  }

  alias TopicsClub.Irc.Session.ConnectionEvents
  alias TopicsClub.Repo

  setup do
    user = AccountsFixtures.user_fixture()

    {:ok, connection} =
      Connections.create(user, %{
        "name" => "connection events",
        "host" => "irc.example.test",
        "port" => 6697,
        "use_tls" => true,
        "nickname" => "mira"
      })

    Phoenix.PubSub.subscribe(TopicsClub.PubSub, "user:#{user.id}")

    state = %{
      connection: connection,
      client: nil,
      client_info: nil,
      registered?: false,
      resumed?: false,
      wirekeeper_resume: nil,
      pending_joins: MapSet.new(),
      pending_commands: %{},
      isupport_received?: false,
      isupport_seen?: false,
      registration_boundary_reached?: false,
      join_validation_ready?: true,
      joins_flushed?: false,
      join_flush_timer: nil,
      sent_joins: MapSet.new(["#sent"]),
      joined_channels: MapSet.new(["#joined"])
    }

    %{connection: connection, state: state, user: user}
  end

  test "marks a registered connection connected and records the transition", context do
    returned = ConnectionEvents.registered(context.state)

    assert returned.registered?
    assert returned.client_info == nil
    assert returned.connection.last_connected_at
    assert Repo.get!(ServerConnection, context.connection.id).last_connected_at

    assert_receive {:server_status,
                    %{
                      server_connection_id: connection_id,
                      status: "connected"
                    }}

    assert connection_id == context.connection.id

    assert [%{kind: "system", body: "Connected to irc.example.test."}] = messages(context)
  end

  test "restores joined memberships before a retained connection registers", context do
    Repo.insert!(%ChannelMembership{
      user_id: context.user.id,
      server_connection_id: context.connection.id,
      channel: "#joined",
      status: "joined",
      auto_join: true
    })

    Repo.insert!(%ChannelMembership{
      user_id: context.user.id,
      server_connection_id: context.connection.id,
      channel: "#pending",
      status: "pending",
      auto_join: true
    })

    resumed = ConnectionEvents.resumed(context.state, %{generation: "generation-1"})

    assert resumed.resumed?
    assert resumed.wirekeeper_resume == %{generation: "generation-1"}
    assert resumed.joined_channels == MapSet.new(["#joined"])
    assert resumed.pending_joins == MapSet.new(["#pending"])
  end

  test "records connection errors and publishes the errored status", context do
    assert context.state == ConnectionEvents.connect_error(context.state, :econnrefused)

    assert_receive {:server_status,
                    %{
                      server_connection_id: connection_id,
                      status: "errored"
                    }}

    assert connection_id == context.connection.id

    assert [
             %{
               kind: "error",
               body: "Connection error for irc.example.test: :econnrefused."
             }
           ] = messages(context)
  end

  test "clears connection-scoped state while reconnecting", context do
    telemetry_id = "connection-reconnect-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        telemetry_id,
        [:topics_club, :irc, :session, :reconnect],
        fn event, measurements, metadata, test_pid ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(telemetry_id) end)

    state = %{
      context.state
      | registered?: true,
        isupport_received?: true,
        isupport_seen?: true,
        registration_boundary_reached?: true,
        join_validation_ready?: true,
        joins_flushed?: true
    }

    returned = ConnectionEvents.reconnecting(state)

    refute returned.registered?
    refute returned.resumed?
    refute returned.isupport_received?
    refute returned.isupport_seen?
    refute returned.registration_boundary_reached?
    refute returned.join_validation_ready?
    refute returned.joins_flushed?
    assert returned.join_flush_timer == nil
    assert returned.sent_joins == MapSet.new()
    assert returned.joined_channels == MapSet.new()

    assert_receive {:server_status, %{status: "connecting"}}

    assert_receive {:telemetry, [:topics_club, :irc, :session, :reconnect],
                    %{system_time: system_time}, %{connection_id: connection_id}}

    assert is_integer(system_time)
    assert connection_id == context.connection.id

    assert [%{kind: "system", body: "Reconnecting to irc.example.test:6697."}] =
             messages(context)
  end

  test "fails pending work and records a disconnect", context do
    {state, invocation, timer} = with_pending_command(context, "disconnect-command")
    returned = ConnectionEvents.disconnected(state)

    assert returned.pending_commands == %{}
    assert Process.read_timer(timer) == false
    assert_receive {:server_status, %{status: "disconnected"}}

    failed = Repo.get!(Message, invocation.id)
    assert failed.metadata["command_status"] == "failed"
    assert failed.metadata["error"] == "Connection closed before completion."

    assert Enum.any?(
             messages(context),
             &(&1.kind == "system" and &1.body == "Disconnected from irc.example.test.")
           )
  end

  test "preserves pending work during an internal Wirekeeper ingestion replay", context do
    {state, invocation, timer} = with_pending_command(context, "replayed-command")

    state =
      Map.merge(state, %{
        wirekeeper_ingestion_retry_started?: true,
        wirekeeper_ingestion_failure: {7, :database_unavailable}
      })

    returned = ConnectionEvents.disconnected(state)

    assert returned.pending_commands == state.pending_commands
    assert is_integer(Process.read_timer(timer))
    refute_receive {:server_status, %{status: "disconnected"}}

    assert Repo.get!(Message, invocation.id).metadata["command_status"] == "sent"
    refute Enum.any?(messages(context), &String.starts_with?(&1.body, "Disconnected from"))

    Process.cancel_timer(timer)
  end

  test "keeps retrying an internal Wirekeeper ingestion replay beyond the upstream limit",
       context do
    client = spawn(fn -> receive do: (:stop -> :ok) end)
    monitor = Process.monitor(client)

    state =
      Map.merge(context.state, %{
        client: client,
        client_monitor: monitor,
        retry_attempt: 5,
        retry_timer: nil,
        wirekeeper_ingestion_retry_started?: true,
        wirekeeper_ingestion_failure: {7, :database_unavailable},
        wirekeeper_node_down?: false,
        connection_issue: nil,
        preserve_error_status?: false
      })

    assert {:noreply, returned} =
             ConnectionEvents.client_exited(
               state,
               monitor,
               client,
               {:wirekeeper_ingestion_failed, :database_unavailable}
             )

    assert returned.retry_attempt == 6
    assert is_reference(returned.retry_timer)
    assert returned.connection_issue == nil
    Process.cancel_timer(returned.retry_timer)
    send(client, :stop)
  end

  test "fails pending work when the session terminates", context do
    {state, invocation, timer} = with_pending_command(context, "terminate-command")
    returned = ConnectionEvents.terminate(state)

    assert returned.pending_commands == %{}
    assert Process.read_timer(timer) == false
    assert_receive {:server_status, %{status: "disconnected"}}

    failed = Repo.get!(Message, invocation.id)
    assert failed.metadata["command_status"] == "failed"
    assert failed.metadata["error"] == "IRC session stopped before completion."
  end

  defp messages(context) do
    MessageHistory.list_buffer_messages(
      context.user,
      "server:#{context.connection.id}"
    )
  end

  defp with_pending_command(context, command_id) do
    {:ok, invocation} =
      CommandMessages.record(
        context.connection,
        "server:#{context.connection.id}",
        "WHOIS mira",
        %{command_id: command_id, command: "WHOIS", command_status: "sent"}
      )

    assert_receive {:buffer_system, %{id: invocation_id}}
    assert invocation_id == invocation.id

    timer = Process.send_after(self(), {:command_timeout, command_id}, 60_000)
    pending = %{invocation: invocation, timer: timer}
    state = %{context.state | pending_commands: %{command_id => pending}}

    {state, invocation, timer}
  end
end
