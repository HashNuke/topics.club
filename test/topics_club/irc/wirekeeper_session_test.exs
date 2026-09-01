defmodule TopicsClub.Irc.WirekeeperSessionTest do
  use TopicsClub.DataCase, async: false

  alias TopicsClub.AccountsFixtures
  alias TopicsClub.Chat

  alias TopicsClub.Chat.{
    ChannelJoinRequest,
    ChannelMembership,
    Connections,
    MembershipLookup,
    Message,
    MessageHistory
  }

  alias TopicsClub.Engine.API
  alias TopicsClub.EngineClient.{Contract, Reply}
  alias TopicsClub.Irc.{Bouncer, CommandRegistry, Session, SessionSupervisor}
  alias TopicsClub.IrcTestServer
  alias TopicsClub.Repo
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

    assert_receive {:irc_server_line, "NAMES #pipe"}, 1_000

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

  test "a rejected managed JOIN is acknowledged without replacing the IRC client or repeating JOIN" do
    server =
      start_supervised!({IrcTestServer, {self(), accept_reconnects?: true, join_replies?: false}})

    {user, connection} = connection_fixture(server, "wirekeeper rejected join")
    close_on_exit(connection)

    assert {:ok, session} = SessionSupervisor.start_session(connection)
    assert_receive {:irc_server_line, "NICK topics_club"}, 1_000
    assert_receive {:irc_server_line, "USER topics_club 0 * topics_club"}, 1_000

    assert_eventually(fn ->
      :sys.get_state(session).registered? and
        match?(
          {:ok, %{attached?: true, buffered_records: 0}},
          Wirekeeper.info(connection.id)
        )
    end)

    assert [{initial_client, nil}] =
             Registry.lookup(
               TopicsClub.Irc.ClientRegistry,
               {connection.user_id, connection.id}
             )

    assert {:ok, %{generation: generation}} = Wirekeeper.info(connection.id)
    flush_server_lines()

    {:ok, info} = Session.connection_info(connection)
    {:ok, intent} = CommandRegistry.resolve("JOIN #startups", info)

    telemetry_id = "wirekeeper-rejected-join-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        telemetry_id,
        [:topics_club, :irc, :ingestion, :failure],
        fn _event, _measurements, metadata, test_pid ->
          send(test_pid, {:join_ingestion_failure, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(telemetry_id) end)

    assert {:ok, %{status: "sent"}} =
             Session.execute(
               connection,
               intent,
               "join-startups",
               "server:#{connection.id}"
             )

    assert_receive {:irc_server_line, "JOIN #startups"}, 1_000

    assert :ok =
             IrcTestServer.send_line(
               server,
               ":topics_club-test 477 topics_club #startups :Cannot join channel (+r) - you need to be identified with services"
             )

    assert_eventually(fn ->
      failed_command =
        user
        |> MessageHistory.list_buffer_messages("server:#{connection.id}")
        |> Enum.find(&(&1.body == "JOIN #startups"))

      (failed_command && failed_command.metadata["command_status"] == "failed") and
        failed_command.metadata["error"] =~ "identified with services" and
        match?(
          %{status: "error"},
          MembershipLookup.find_by_channel(connection, "#startups", :ascii)
        ) and
        match?(
          {:ok, %{generation: ^generation, attached?: true, buffered_records: 0}},
          Wirekeeper.info(connection.id)
        )
    end)

    assert [{^initial_client, nil}] =
             Registry.lookup(
               TopicsClub.Irc.ClientRegistry,
               {connection.user_id, connection.id}
             )

    refute_receive {:join_ingestion_failure, %{connection_id: _connection_id}},
                   300,
                   "a normal JOIN rejection was misclassified as a persistence failure for connection #{connection.id}"

    refute Enum.any?(
             MessageHistory.list_buffer_messages(user, "server:#{connection.id}"),
             &String.starts_with?(&1.body, [
               "Disconnected from",
               "Connection lost",
               "Reconnected to"
             ])
           )

    refute_receive {:irc_server_line, "JOIN #startups"}, 300
    refute_connection_setup_lines()
  end

  test "resuming a retained socket does not retransmit a JOIN that was already sent" do
    server =
      start_supervised!({IrcTestServer, {self(), accept_reconnects?: true, join_replies?: false}})

    {_user, connection} = connection_fixture(server, "wirekeeper pending join resume")
    close_on_exit(connection)

    assert {:ok, first_session} = SessionSupervisor.start_session(connection)
    assert_receive {:irc_server_line, "NICK topics_club"}, 1_000
    assert_receive {:irc_server_line, "USER topics_club 0 * topics_club"}, 1_000

    assert_eventually(fn ->
      :sys.get_state(first_session).registered? and
        match?(
          {:ok, %{attached?: true, buffered_records: 0}},
          Wirekeeper.info(connection.id)
        )
    end)

    {:ok, info} = Session.connection_info(connection)
    {:ok, intent} = CommandRegistry.resolve("JOIN #startups", info)

    assert {:ok, %{status: "sent"}} =
             Session.execute(
               connection,
               intent,
               "join-before-engine-restart",
               "server:#{connection.id}"
             )

    assert_receive {:irc_server_line, "JOIN #startups"}, 1_000
    assert {:ok, %{generation: generation}} = Wirekeeper.info(connection.id)

    assert :ok = SessionSupervisor.stop_for_restart(connection)
    first_ref = Process.monitor(first_session)
    assert_receive {:DOWN, ^first_ref, :process, ^first_session, _reason}, 1_000

    flush_server_lines()
    assert {:ok, resumed_session} = SessionSupervisor.start_session(connection)

    assert_eventually(fn ->
      :sys.get_state(resumed_session).resumed? and
        match?(
          {:ok, %{generation: ^generation, attached?: true, buffered_records: 0}},
          Wirekeeper.info(connection.id)
        )
    end)

    refute_receive {:irc_server_line, "JOIN #startups"}, 300
    refute_connection_setup_lines()
  end

  test "resuming a retained socket transmits a pending JOIN that was never sent" do
    server =
      start_supervised!({IrcTestServer, {self(), accept_reconnects?: true, join_replies?: false}})

    {user, connection} = connection_fixture(server, "wirekeeper unsent join resume")
    close_on_exit(connection)

    assert {:ok, first_session} = SessionSupervisor.start_session(connection)
    assert_receive {:irc_server_line, "NICK topics_club"}, 1_000
    assert_receive {:irc_server_line, "USER topics_club 0 * topics_club"}, 1_000

    assert_eventually(fn ->
      :sys.get_state(first_session).registered? and
        match?({:ok, %{attached?: true}}, Wirekeeper.info(connection.id))
    end)

    assert {:ok, %{generation: generation}} = Wirekeeper.info(connection.id)
    assert :ok = SessionSupervisor.stop_for_restart(connection)
    first_ref = Process.monitor(first_session)
    assert_receive {:DOWN, ^first_ref, :process, ^first_session, _reason}, 1_000

    assert {:ok, membership} = ChannelJoinRequest.request(user, connection, "#never-sent")
    assert is_binary(membership.join_attempt_id)

    flush_server_lines()
    assert {:ok, resumed_session} = SessionSupervisor.start_session(connection)

    assert_receive {:irc_server_line, "JOIN #never-sent"}, 1_000

    assert_eventually(fn ->
      :sys.get_state(resumed_session).resumed? and
        match?(
          {:ok, %{generation: ^generation, attached?: true}},
          Wirekeeper.info(connection.id)
        )
    end)

    refute_receive {:irc_server_line, "JOIN #never-sent"}, 300
    refute_connection_setup_lines()
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

  test "an authoritative disconnect closes a detached generation before reconnecting fresh" do
    server = start_supervised!({IrcTestServer, {self(), accept_reconnects?: true}})
    {user, connection} = connection_fixture(server, "wirekeeper authoritative disconnect")
    close_on_exit(connection)

    assert {:ok, first_session} = SessionSupervisor.start_session(connection)
    assert_receive {:irc_server_line, "NICK topics_club"}, 1_000
    assert_receive {:irc_server_line, "USER topics_club 0 * topics_club"}, 1_000

    assert_eventually(fn ->
      :sys.get_state(first_session).registered? and
        match?(
          {:ok, %{attached?: true, buffered_records: 0}},
          Wirekeeper.info(connection.id)
        )
    end)

    assert {:ok, %{generation: first_generation}} = Wirekeeper.info(connection.id)
    assert :ok = SessionSupervisor.stop_for_restart(connection)

    first_session_ref = Process.monitor(first_session)
    assert_receive {:DOWN, ^first_session_ref, :process, ^first_session, _reason}, 1_000

    assert_eventually(fn ->
      match?({:ok, %{attached?: false}}, Wirekeeper.info(connection.id))
    end)

    assert {:ok, %{status: "disconnected", connection: %{desired_state: "paused"}}} =
             dispatch_engine(:disconnect_connection, user.id, connection.id)

    assert_eventually(fn -> Wirekeeper.info(connection.id) == {:error, :not_found} end)

    flush_server_lines()

    assert {:ok, %{connection: %{desired_state: "connected"}}} =
             dispatch_engine(:ensure_connection, user.id, connection.id, %{intent: "active"})

    assert_receive {:irc_server_line, "NICK topics_club"}, 1_000
    assert_receive {:irc_server_line, "USER topics_club 0 * topics_club"}, 1_000

    assert_eventually(fn ->
      replacement = TopicsClub.Irc.SessionLocator.whereis(connection)

      is_pid(replacement) and :sys.get_state(replacement).registered? and
        match?(
          {:ok, %{generation: generation, attached?: true, buffered_records: 0}}
          when generation != first_generation,
          Wirekeeper.info(connection.id)
        )
    end)
  end

  test "edited credentials reject the retained checkpoint and reconnect with the new secret" do
    server = start_supervised!({IrcTestServer, {self(), accept_reconnects?: true}})
    user = AccountsFixtures.user_fixture()

    assert {:ok, connection} =
             Connections.create(user, %{
               "name" => "wirekeeper credential replacement",
               "host" => "127.0.0.1",
               "port" => IrcTestServer.port(server),
               "use_tls" => false,
               "nickname" => "topics_club",
               "sasl_username" => "topics-club-account",
               "sasl_password" => "old-secret"
             })

    close_on_exit(connection)

    assert {:ok, session} = SessionSupervisor.start_session(connection)
    assert_receive {:irc_server_line, "NICK topics_club"}, 1_000
    assert_receive {:irc_server_line, "USER topics_club 0 * topics_club"}, 1_000

    assert_eventually(fn ->
      :sys.get_state(session).registered? and
        match?(
          {:ok, %{attached?: true, buffered_records: 0}},
          Wirekeeper.info(connection.id)
        )
    end)

    assert {:ok, %{generation: first_generation}} = Wirekeeper.info(connection.id)
    flush_server_lines()

    assert {:ok, updated} =
             Connections.update(user, connection.id, %{"sasl_password" => "new-secret"})

    assert updated.sasl_password == "new-secret"
    assert :ok = SessionSupervisor.stop_for_restart(updated)

    assert_eventually(fn ->
      match?(
        {:ok, %{generation: ^first_generation, attached?: false}},
        Wirekeeper.info(connection.id)
      )
    end)

    assert {:ok, _replacement_session} = SessionSupervisor.start_session(updated)
    assert_receive {:irc_server_line, "NICK topics_club"}, 1_000
    assert_receive {:irc_server_line, "USER topics_club 0 * topics_club"}, 1_000

    assert_eventually(fn ->
      replacement = TopicsClub.Irc.SessionLocator.whereis(updated)

      is_pid(replacement) and :sys.get_state(replacement).registered? and
        match?(
          {:ok, %{generation: generation, attached?: true, buffered_records: 0}}
          when generation != first_generation,
          Wirekeeper.info(connection.id)
        )
    end)
  end

  test "the inactive sweep closes a detached connection that was skipped during restoration",
       context do
    server = start_supervised!({IrcTestServer, self()})
    {user, connection} = connection_fixture(server, "wirekeeper skipped restoration")
    close_on_exit(connection)

    user
    |> Ecto.Changeset.change(last_seen_at: DateTime.add(DateTime.utc_now(:second), -25, :hour))
    |> Repo.update!()

    assert {:ok, session} = SessionSupervisor.start_session(connection)
    assert_receive {:irc_server_line, "NICK topics_club"}, 1_000
    assert_receive {:irc_server_line, "USER topics_club 0 * topics_club"}, 1_000

    assert_eventually(fn ->
      match?({:ok, %{attached?: true}}, Wirekeeper.info(connection.id))
    end)

    assert :ok = SessionSupervisor.stop_for_restart(connection)
    session_ref = Process.monitor(session)
    assert_receive {:DOWN, ^session_ref, :process, ^session, _reason}, 1_000

    assert_eventually(fn ->
      match?({:ok, %{attached?: false}}, Wirekeeper.info(connection.id))
    end)

    bouncer =
      start_supervised!(
        {Bouncer,
         enabled?: true, restore_on_start?: false, sweep_interval: :timer.hours(1), name: nil}
      )

    Ecto.Adapters.SQL.Sandbox.allow(Repo, context.sandbox_owner, bouncer)
    send(bouncer, :start_recent_sessions)
    _ = :sys.get_state(bouncer)
    assert TopicsClub.Irc.SessionLocator.whereis(connection) == nil
    assert {:ok, %{attached?: false}} = Wirekeeper.info(connection.id)

    send(bouncer, :sweep_inactive_sessions)
    _ = :sys.get_state(bouncer)

    assert_eventually(fn -> Wirekeeper.info(connection.id) == {:error, :not_found} end)
  end

  test "a failed inbound transaction keeps its Wirekeeper record for replay" do
    Application.put_env(:topics_club_engine, :session_retry_delay_ms, 500)
    server = start_supervised!({IrcTestServer, {self(), accept_reconnects?: true}})
    {user, connection} = connection_fixture(server, "wirekeeper failed persistence")
    assert {:ok, membership} = Chat.join_channel(user, connection, "#pipe")
    close_on_exit(connection)

    assert {:ok, session} = SessionSupervisor.start_session(connection)
    assert_receive {:irc_server_line, "NICK topics_club"}, 1_000
    assert_receive {:irc_server_line, "USER topics_club 0 * topics_club"}, 1_000
    assert_receive {:irc_server_line, "JOIN #pipe"}, 1_000

    assert_eventually(fn ->
      :sys.get_state(session).registered? and
        match?(
          {:ok, %{attached?: true, buffered_records: 0}},
          Wirekeeper.info(connection.id)
        )
    end)

    assert {:ok, %{acked_through: acked_before_failure}} = Wirekeeper.info(connection.id)

    membership
    |> Repo.reload!()
    |> Ecto.Changeset.change(status: "pending")
    |> Repo.update!()

    body = "must survive a failed transaction"
    assert :ok = IrcTestServer.broadcast(server, "#pipe", "akash", body)

    later_body = "- must wait behind the failed record"

    assert :ok =
             IrcTestServer.send_line(
               server,
               ":irc.example.test 372 topics_club :#{later_body}"
             )

    assert_eventually(fn ->
      match?(
        {:ok, %{buffered_records: count, in_flight_records: in_flight}}
        when count >= 1 and in_flight >= 1,
        Wirekeeper.info(connection.id)
      )
    end)

    assert {:ok, %{acked_through: acked_after_failure}} = Wirekeeper.info(connection.id)
    assert acked_after_failure >= acked_before_failure

    refute_receive {:buffer_message, %{body: ^body}}, 600

    assert {:ok, %{acked_through: ^acked_after_failure, buffered_records: retained_count}} =
             Wirekeeper.info(connection.id)

    assert retained_count >= 1

    assert message_count(user, membership.id, body) == 0
    refute Repo.get_by(Message, server_connection_id: connection.id, body: later_body)

    membership
    |> Repo.reload!()
    |> Ecto.Changeset.change(status: "joined")
    |> Repo.update!()

    assert :ok = SessionSupervisor.stop_for_restart(connection)
    assert {:ok, _replacement_session} = SessionSupervisor.start_session(connection)

    assert_eventually(fn ->
      message_count(user, membership.id, body) == 1 and
        not is_nil(Repo.get_by(Message, server_connection_id: connection.id, body: later_body)) and
        match?({:ok, %{buffered_records: 0}}, Wirekeeper.info(connection.id))
    end)
  end

  test "a failed recorded IRC event keeps its Wirekeeper record for replay" do
    Application.put_env(:topics_club_engine, :session_retry_delay_ms, 500)
    server = start_supervised!({IrcTestServer, {self(), accept_reconnects?: true}})
    {user, connection} = connection_fixture(server, "wirekeeper failed event recorder")
    assert {:ok, membership} = Chat.join_channel(user, connection, "#pipe")
    close_on_exit(connection)

    assert {:ok, session} = SessionSupervisor.start_session(connection)
    assert_receive {:irc_server_line, "NICK topics_club"}, 1_000
    assert_receive {:irc_server_line, "USER topics_club 0 * topics_club"}, 1_000
    assert_receive {:irc_server_line, "JOIN #pipe"}, 1_000

    assert_eventually(fn ->
      :sys.get_state(session).registered? and
        match?(
          {:ok, %{attached?: true, buffered_records: 0}},
          Wirekeeper.info(connection.id)
        )
    end)

    Repo.delete!(membership)

    assert :ok =
             IrcTestServer.send_line(
               server,
               ":akash!user@test TOPIC #pipe :a retained topic"
             )

    assert_eventually(fn ->
      match?(
        {:ok, %{buffered_records: count, in_flight_records: in_flight}}
        when count >= 1 and in_flight >= 1,
        Wirekeeper.info(connection.id)
      )
    end)

    body = "akash changed the topic to: a retained topic"
    refute Repo.get_by(Message, body: body)

    replacement_membership =
      Repo.insert!(%ChannelMembership{
        user_id: user.id,
        server_connection_id: connection.id,
        channel: "#pipe",
        status: "joined"
      })

    assert_eventually(fn ->
      message_count(user, replacement_membership.id, body) == 1 and
        match?({:ok, %{buffered_records: 0}}, Wirekeeper.info(connection.id))
    end)
  end

  test "a committed inbound message is idempotent when its unacked record is replayed" do
    server = start_supervised!({IrcTestServer, {self(), accept_reconnects?: true}})
    {user, connection} = connection_fixture(server, "wirekeeper committed replay")
    assert {:ok, membership} = Chat.join_channel(user, connection, "#pipe")
    close_on_exit(connection)

    assert {:ok, session} = SessionSupervisor.start_session(connection)
    assert_receive {:irc_server_line, "NICK topics_club"}, 1_000
    assert_receive {:irc_server_line, "USER topics_club 0 * topics_club"}, 1_000
    assert_receive {:irc_server_line, "JOIN #pipe"}, 1_000

    assert_eventually(fn ->
      :sys.get_state(session).registered? and
        match?(
          {:ok, %{attached?: true, buffered_records: 0}},
          Wirekeeper.info(connection.id)
        )
    end)

    barrier_ref = make_ref()

    previous_barrier =
      Application.get_env(:topics_club_core, :connection_effects_before_lock_barrier)

    Application.put_env(
      :topics_club_core,
      :connection_effects_before_lock_barrier,
      {self(), barrier_ref}
    )

    on_exit(fn -> restore_core_effects_barrier(previous_barrier) end)

    body = "committed before its Wirekeeper acknowledgement"
    assert :ok = IrcTestServer.broadcast(server, "#pipe", "akash", body)

    _effects_pid =
      await_effects_barrier(session, barrier_ref, connection.id, fn ->
        message_count(user, membership.id, body) == 1
      end)

    assert message_count(user, membership.id, body) == 1

    Application.delete_env(:topics_club_core, :connection_effects_before_lock_barrier)
    assert :ok = SessionSupervisor.stop_for_restart(connection)

    assert_eventually(fn ->
      match?(
        {:ok, %{attached?: false, buffered_records: count}} when count >= 1,
        Wirekeeper.info(connection.id)
      )
    end)

    assert {:ok, _replacement_session} = SessionSupervisor.start_session(connection)

    assert_eventually(fn ->
      match?({:ok, %{buffered_records: 0}}, Wirekeeper.info(connection.id))
    end)

    assert message_count(user, membership.id, body) == 1
  end

  test "a committed recorded IRC event is idempotent when its unacked record is replayed" do
    server = start_supervised!({IrcTestServer, {self(), accept_reconnects?: true}})
    {user, connection} = connection_fixture(server, "wirekeeper committed event replay")
    assert {:ok, membership} = Chat.join_channel(user, connection, "#pipe")
    close_on_exit(connection)

    assert {:ok, session} = SessionSupervisor.start_session(connection)
    assert_receive {:irc_server_line, "NICK topics_club"}, 1_000
    assert_receive {:irc_server_line, "USER topics_club 0 * topics_club"}, 1_000
    assert_receive {:irc_server_line, "JOIN #pipe"}, 1_000

    assert_eventually(fn ->
      :sys.get_state(session).registered? and
        match?(
          {:ok, %{attached?: true, buffered_records: 0}},
          Wirekeeper.info(connection.id)
        )
    end)

    barrier_ref = make_ref()

    previous_barrier =
      Application.get_env(:topics_club_core, :connection_effects_before_lock_barrier)

    Application.put_env(
      :topics_club_core,
      :connection_effects_before_lock_barrier,
      {self(), barrier_ref}
    )

    on_exit(fn -> restore_core_effects_barrier(previous_barrier) end)

    body = "akash changed the topic to: committed before acknowledgement"

    assert :ok =
             IrcTestServer.send_line(
               server,
               ":akash!user@test TOPIC #pipe :committed before acknowledgement"
             )

    _effects_pid =
      await_effects_barrier(session, barrier_ref, connection.id, fn ->
        message_count(user, membership.id, body) == 1
      end)

    assert message_count(user, membership.id, body) == 1

    Application.delete_env(:topics_club_core, :connection_effects_before_lock_barrier)
    assert :ok = SessionSupervisor.stop_for_restart(connection)

    assert_eventually(fn ->
      match?(
        {:ok, %{attached?: false, buffered_records: count}} when count >= 1,
        Wirekeeper.info(connection.id)
      )
    end)

    assert {:ok, _replacement_session} = SessionSupervisor.start_session(connection)

    assert_eventually(fn ->
      match?({:ok, %{buffered_records: 0}}, Wirekeeper.info(connection.id))
    end)

    assert message_count(user, membership.id, body) == 1
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

    assert_eventually(fn ->
      :sys.get_state(session).registered? and
        match?(
          {:ok, %{attached?: true, buffered_records: 0}},
          Wirekeeper.info(connection.id)
        )
    end)
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

  @tag :capture_log
  test "a Wirekeeper partition retries beyond ordinary exhaustion and resumes its generation" do
    Application.put_env(:topics_club_engine, :session_retry_delay_ms, 50)
    server = start_supervised!({IrcTestServer, self()})
    {user, connection} = connection_fixture(server, "wirekeeper exhausted outage")
    close_on_exit(connection)

    user
    |> Ecto.Changeset.change(last_seen_at: DateTime.utc_now(:second))
    |> Repo.update!()

    assert {:ok, session} = SessionSupervisor.start_session(connection)
    assert_receive {:irc_server_line, "NICK topics_club"}, 1_000
    assert_receive {:irc_server_line, "USER topics_club 0 * topics_club"}, 1_000

    assert_eventually(fn ->
      :sys.get_state(session).registered? and
        match?(
          {:ok, %{attached?: true, buffered_records: 0, acked_through: sequence}}
          when sequence > 0,
          Wirekeeper.info(connection.id)
        )
    end)

    session_ref = Process.monitor(session)

    Application.put_env(
      :topics_club_engine,
      :irc_transport,
      {:wirekeeper, :missing_wirekeeper@localhost}
    )

    assert [{client, nil}] =
             Registry.lookup(
               TopicsClub.Irc.ClientRegistry,
               {connection.user_id, connection.id}
             )

    send(client, {:nodedown, node()})
    refute_receive {:DOWN, ^session_ref, :process, ^session, _reason}, 600

    assert Repo.get!(TopicsClub.Chat.ServerConnection, connection.id).desired_state == "connected"
    assert session == TopicsClub.Irc.SessionLocator.whereis(connection)
    assert {:ok, %{generation: retained_generation}} = Wirekeeper.info(connection.id)

    Application.put_env(:topics_club_engine, :irc_transport, {:wirekeeper, node()})

    assert_eventually(fn ->
      state = :sys.get_state(session)

      state.registered? and state.retry_attempt == 0 and
        match?(
          {:ok, %{generation: ^retained_generation, attached?: true}},
          Wirekeeper.info(connection.id)
        )
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
      await_session_quiescence(connection, 1_000)
      _result = SessionSupervisor.stop_for_deletion(connection)
    end)
  end

  defp await_session_quiescence(_connection, 0), do: :ok

  defp await_session_quiescence(connection, attempts) do
    case {TopicsClub.Irc.SessionLocator.whereis(connection), Wirekeeper.info(connection.id)} do
      {pid, {:ok, %{attached?: true, buffered_records: 0}}} when is_pid(pid) ->
        try do
          _state = :sys.get_state(pid)
          :ok
        catch
          :exit, _reason -> :ok
        end

      {_pid, {:ok, %{attached?: true}}} ->
        receive do
        after
          2 -> await_session_quiescence(connection, attempts - 1)
        end

      _detached_or_closed ->
        :ok
    end
  end

  defp message_count(user, membership_id, body) do
    user
    |> MessageHistory.list_messages(membership_id)
    |> Enum.count(&(&1.body == body))
  end

  defp dispatch_engine(operation, user_id, connection_id, payload \\ %{}) do
    {:ok, request} = Contract.new(operation, user_id, connection_id, payload)
    request |> API.dispatch() |> Reply.decode(request)
  end

  defp await_effects_barrier(session, barrier_ref, connection_id, callback, attempts \\ 10)

  defp await_effects_barrier(session, barrier_ref, connection_id, callback, attempts)
       when attempts > 0 do
    receive do
      {:connection_effects_paused, ^session, ^barrier_ref, ^connection_id} ->
        if callback.() do
          session
        else
          send(session, {:continue_connection_effects, barrier_ref})
          await_effects_barrier(session, barrier_ref, connection_id, callback, attempts - 1)
        end
    after
      5_000 -> flunk("connection effects did not pause after the expected commit")
    end
  end

  defp await_effects_barrier(_session, _barrier_ref, _connection_id, _callback, 0),
    do: flunk("expected committed effect did not reach its barrier")

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

  defp restore_core_effects_barrier(nil),
    do: Application.delete_env(:topics_club_core, :connection_effects_before_lock_barrier)

  defp restore_core_effects_barrier(previous),
    do:
      Application.put_env(
        :topics_club_core,
        :connection_effects_before_lock_barrier,
        previous
      )
end
