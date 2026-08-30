if System.get_env("TOPICS_CLUB_LOCAL_IRC_INTEGRATION") == "1" do
  defmodule TopicsClub.Irc.LocalIntegrationTest do
    use ExUnit.Case, async: false

    import Ecto.Query
    import ExUnit.CaptureLog

    alias TopicsClub.Accounts.User
    alias TopicsClub.AccountsFixtures
    alias TopicsClub.Chat
    alias TopicsClub.Chat.{Connections, Message, ServerConnection}
    alias TopicsClub.Irc.{Session, SessionLocator, SessionSupervisor}
    alias TopicsClub.Repo

    @host "127.0.0.1"
    @port 6669
    @session_count 12

    setup do
      prefix = "local-deploy-#{System.unique_integer([:positive])}"
      :ok = Ecto.Adapters.SQL.Sandbox.mode(Repo, :auto)

      on_exit(fn ->
        try do
          capture_log(fn ->
            unless :topics_club_gateway in started_applications() do
              {:ok, _applications} = Application.ensure_all_started(:topics_club_gateway)
            end

            user_ids =
              User
              |> where([user], like(user.email, ^"#{prefix}-%"))
              |> select([user], user.id)
              |> Repo.all()

            ServerConnection
            |> where([connection], connection.user_id in ^user_ids)
            |> Repo.all()
            |> Enum.each(&SessionSupervisor.stop_session/1)

            Repo.delete_all(from(user in User, where: user.id in ^user_ids))
          end)
        after
          :ok = Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual)
        end
      end)

      %{prefix: prefix}
    end

    test "local InspIRCd relays messages between IRC clients and irssi is available" do
      assert System.find_executable("irssi")

      unique = System.unique_integer([:positive]) |> rem(100_000)
      channel = "#topics_club-it-#{unique}"
      listener_nick = "listen#{unique}"
      speaker_nick = "speak#{unique}"

      {:ok, listener} = connect_second_client(listener_nick)
      {:ok, speaker} = connect_second_client(speaker_nick)

      extra_clients =
        for index <- 1..2 do
          {:ok, client} = connect_second_client("extra#{unique}#{index}")
          client
        end

      :ok = send_line(listener, "JOIN #{channel}")

      :ok =
        recv_until(
          listener,
          &(String.contains?(&1, " 366 ") and String.contains?(&1, channel)),
          5_000
        )

      :ok = send_line(speaker, "JOIN #{channel}")

      :ok =
        recv_until(
          listener,
          &(String.contains?(&1, "#{speaker_nick}!") and String.contains?(&1, " JOIN ") and
              String.contains?(&1, channel)),
          5_000
        )

      :ok = send_line(speaker, "PRIVMSG #{channel} :hello from local integration")

      assert :ok =
               recv_until(
                 listener,
                 &(String.contains?(&1, "#{speaker_nick}!") and
                     String.contains?(&1, " PRIVMSG #{channel} :hello from local integration")),
                 5_000
               )

      send_line(speaker, "QUIT :done")
      send_line(listener, "QUIT :done")
      Enum.each(extra_clients, &send_line(&1, "QUIT :done"))
      :gen_tcp.close(speaker)
      :gen_tcp.close(listener)
      Enum.each(extra_clients, &:gen_tcp.close/1)
    end

    test "delayjoin hides a rejoin but does not provide restart grace for a visible user" do
      unique = System.unique_integer([:positive]) |> rem(100_000)
      channel = "#delayjoin-#{unique}"
      observer_nick = "observe#{unique}"
      subject_nick = "subject#{unique}"

      {:ok, observer} = connect_second_client(observer_nick)
      {:ok, subject} = connect_second_client(subject_nick)

      :ok = send_line(observer, "JOIN #{channel}")
      :ok = recv_until(observer, &end_of_names?(&1, channel), 5_000)
      :ok = send_line(observer, "MODE #{channel} +D")

      assert :ok =
               recv_until(
                 observer,
                 &(String.contains?(&1, " MODE #{channel} ") and
                     String.ends_with?(String.trim(&1), "+D")),
                 5_000
               )

      :ok = send_line(subject, "JOIN #{channel}")
      :ok = recv_until(subject, &end_of_names?(&1, channel), 5_000)

      assert :ok =
               refute_until(
                 observer,
                 &nick_event?(&1, subject_nick, "JOIN"),
                 500
               )

      :ok = send_line(subject, "PRIVMSG #{channel} :visible before restart")
      assert :ok = recv_until(observer, &nick_event?(&1, subject_nick, "JOIN"), 5_000)

      assert :ok =
               recv_until(
                 observer,
                 &(String.contains?(&1, ":#{subject_nick}!") and
                     String.contains?(&1, " PRIVMSG #{channel} :visible before restart")),
                 5_000
               )

      :ok = :gen_tcp.close(subject)
      assert :ok = recv_until(observer, &nick_event?(&1, subject_nick, "QUIT"), 5_000)

      {:ok, resumed_subject} = connect_second_client(subject_nick)
      :ok = send_line(resumed_subject, "JOIN #{channel}")
      :ok = recv_until(resumed_subject, &end_of_names?(&1, channel), 5_000)

      assert :ok =
               refute_until(
                 observer,
                 &nick_event?(&1, subject_nick, "JOIN"),
                 500
               )

      :ok = send_line(resumed_subject, "PRIVMSG #{channel} :visible after restart")
      assert :ok = recv_until(observer, &nick_event?(&1, subject_nick, "JOIN"), 5_000)

      assert :ok =
               recv_until(
                 observer,
                 &(String.contains?(&1, ":#{subject_nick}!") and
                     String.contains?(&1, " PRIVMSG #{channel} :visible after restart")),
                 5_000
               )

      send_line(resumed_subject, "QUIT :done")
      send_line(observer, "QUIT :done")
      :gen_tcp.close(resumed_subject)
      :gen_tcp.close(observer)
    end

    test "a gateway deploy preserves twelve IRC sessions and two-way traffic", %{prefix: prefix} do
      capture_log(fn -> exercise_gateway_deploy(prefix) end)
    end

    defp exercise_gateway_deploy(prefix) do
      unique = System.unique_integer([:positive]) |> rem(100_000)
      channel = "#deploy-#{unique}"
      observer_nick = "watch#{unique}"
      inbound_body = "traffic received while the gateway is stopped"
      outbound_body = "traffic sent after the gateway restarted"

      {:ok, observer} = connect_second_client(observer_nick)
      on_exit(fn -> :gen_tcp.close(observer) end)

      :ok = send_line(observer, "JOIN #{channel}")
      :ok = recv_until(observer, &end_of_names?(&1, channel), 5_000)

      sessions =
        1..@session_count
        |> Enum.reduce([], fn index, connected_sessions ->
          user =
            AccountsFixtures.user_fixture(%{
              email: "#{prefix}-#{index}@example.com"
            })

          nick = "deploy#{unique}#{index}"

          assert {:ok, connection} =
                   Connections.create(user, %{
                     "name" => "local deploy #{index}",
                     "host" => @host,
                     "port" => @port,
                     "use_tls" => false,
                     "nickname" => nick
                   })

          assert {:ok, membership} = Chat.join_channel(user, connection, channel)
          assert {:ok, session} = SessionSupervisor.start_session(connection)
          assert :ok = recv_until(observer, &nick_event?(&1, nick, "JOIN"), 15_000)

          current = %{connection: connection, membership: membership, nick: nick, pid: session}
          Enum.each([current | connected_sessions], &:sys.get_state(&1.pid, 15_000))
          [current | connected_sessions]
        end)
        |> Enum.reverse()

      membership_ids = Enum.map(sessions, & &1.membership.id)
      nicks = Enum.map(sessions, & &1.nick)

      assert :ok = eventually(fn -> joined_memberships(membership_ids) == @session_count end)
      assert :ok = refute_until(observer, &managed_connection_event?(&1, nicks), 250)

      gateway = Process.whereis(TopicsClubWeb.Supervisor)
      engine = Process.whereis(TopicsClub.EngineSupervisor)
      assert is_pid(gateway)
      assert is_pid(engine)

      gateway_ref = Process.monitor(gateway)
      engine_ref = Process.monitor(engine)

      assert :ok = Application.stop(:topics_club_gateway)
      assert_receive {:DOWN, ^gateway_ref, :process, ^gateway, _reason}, 5_000
      refute_receive {:DOWN, ^engine_ref, :process, ^engine, _reason}, 100

      Enum.each(sessions, fn session ->
        assert SessionLocator.whereis(session.connection) == session.pid
      end)

      :ok = send_line(observer, "PRIVMSG #{channel} :#{inbound_body}")

      assert :ok =
               eventually(fn ->
                 message_count(membership_ids, inbound_body) == @session_count
               end)

      assert {:ok, _applications} = Application.ensure_all_started(:topics_club_gateway)

      Enum.each(sessions, fn session ->
        assert SessionLocator.whereis(session.connection) == session.pid
      end)

      assert :ok = refute_until(observer, &managed_connection_event?(&1, nicks), 1_000)

      first = hd(sessions)
      assert {:ok, _message} = Session.say(first.connection, channel, outbound_body)

      assert :ok =
               recv_until(
                 observer,
                 &(String.contains?(&1, ":#{first.nick}!") and
                     String.contains?(&1, " PRIVMSG #{channel} :#{outbound_body}")),
                 5_000
               )

      send_line(observer, "QUIT :done")
      :gen_tcp.close(observer)
    end

    defp connect_second_client(nick) do
      with {:ok, socket} <-
             :gen_tcp.connect(
               String.to_charlist(@host),
               @port,
               [:binary, packet: :line, active: false],
               1_000
             ),
           :ok <- send_line(socket, "NICK #{nick}"),
           :ok <- send_line(socket, "USER irctest 0 * #{nick}"),
           :ok <- recv_until(socket, &String.contains?(&1, " 001 "), 15_000) do
        {:ok, socket}
      end
    end

    defp send_line(socket, line), do: :gen_tcp.send(socket, line <> "\r\n")

    defp recv_until(socket, predicate, timeout_ms) do
      deadline = System.monotonic_time(:millisecond) + timeout_ms
      recv_until_deadline(socket, predicate, deadline)
    end

    defp recv_until_deadline(socket, predicate, deadline) do
      if System.monotonic_time(:millisecond) > deadline do
        {:error, :timeout}
      else
        case :gen_tcp.recv(socket, 0, 250) do
          {:ok, "PING " <> token} ->
            send_line(socket, "PONG #{String.trim(token)}")
            recv_until_deadline(socket, predicate, deadline)

          {:ok, line} ->
            if predicate.(line), do: :ok, else: recv_until_deadline(socket, predicate, deadline)

          {:error, :timeout} ->
            recv_until_deadline(socket, predicate, deadline)

          {:error, reason} ->
            {:error, reason}
        end
      end
    end

    defp refute_until(socket, predicate, timeout_ms) do
      deadline = System.monotonic_time(:millisecond) + timeout_ms
      refute_until_deadline(socket, predicate, deadline)
    end

    defp refute_until_deadline(socket, predicate, deadline) do
      remaining = deadline - System.monotonic_time(:millisecond)

      if remaining <= 0 do
        :ok
      else
        case :gen_tcp.recv(socket, 0, min(remaining, 250)) do
          {:ok, "PING " <> token} ->
            send_line(socket, "PONG #{String.trim(token)}")
            refute_until_deadline(socket, predicate, deadline)

          {:ok, line} ->
            if predicate.(line) do
              {:error, {:unexpected_line, String.trim(line)}}
            else
              refute_until_deadline(socket, predicate, deadline)
            end

          {:error, :timeout} ->
            refute_until_deadline(socket, predicate, deadline)

          {:error, reason} ->
            {:error, reason}
        end
      end
    end

    defp end_of_names?(line, channel),
      do: String.contains?(line, " 366 ") and String.contains?(line, channel)

    defp nick_event?(line, nick, command),
      do: String.contains?(line, ":#{nick}!") and String.contains?(line, " #{command} ")

    defp managed_connection_event?(line, nicks) do
      Enum.any?(nicks, fn nick ->
        nick_event?(line, nick, "JOIN") or nick_event?(line, nick, "QUIT")
      end)
    end

    defp joined_memberships(membership_ids) do
      TopicsClub.Chat.ChannelMembership
      |> where([membership], membership.id in ^membership_ids and membership.status == "joined")
      |> Repo.aggregate(:count, :id)
    end

    defp message_count(membership_ids, body) do
      Message
      |> where(
        [message],
        message.channel_membership_id in ^membership_ids and message.body == ^body
      )
      |> Repo.aggregate(:count, :id)
    end

    defp eventually(predicate, timeout_ms \\ 5_000) do
      deadline = System.monotonic_time(:millisecond) + timeout_ms
      eventually_until(predicate, deadline)
    end

    defp eventually_until(predicate, deadline) do
      cond do
        predicate.() ->
          :ok

        System.monotonic_time(:millisecond) >= deadline ->
          {:error, :timeout}

        true ->
          receive do
          after
            25 -> eventually_until(predicate, deadline)
          end
      end
    end

    defp started_applications do
      Application.started_applications()
      |> Enum.map(&elem(&1, 0))
    end
  end
end
