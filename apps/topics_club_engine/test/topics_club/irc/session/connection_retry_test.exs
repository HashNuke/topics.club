defmodule TopicsClub.Irc.Session.ConnectionRetryTest do
  use TopicsClub.DataCase, async: false

  import Ecto.Query

  alias TopicsClub.Accounts.User
  alias TopicsClub.Chat.{Message, ServerConnection}
  alias TopicsClub.Irc.Session

  setup do
    previous_delay = Application.get_env(:topics_club_engine, :session_retry_delay_ms)
    Application.put_env(:topics_club_engine, :session_retry_delay_ms, 0)

    on_exit(fn ->
      if is_nil(previous_delay) do
        Application.delete_env(:topics_club_engine, :session_retry_delay_ms)
      else
        Application.put_env(:topics_club_engine, :session_retry_delay_ms, previous_delay)
      end
    end)

    :ok
  end

  @tag capture_log: true
  test "stops after five retries and records one actionable issue" do
    telemetry_id = "connection-retry-test-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        telemetry_id,
        [:topics_club, :irc, :session, :reconnect],
        fn _event, measurements, metadata, test_pid ->
          send(test_pid, {:retry_attempt, measurements.attempt, metadata.connection_id})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(telemetry_id) end)

    user =
      Repo.insert!(%User{email: "retry-#{System.unique_integer([:positive])}@example.test"})

    connection =
      Repo.insert!(%ServerConnection{
        user_id: user.id,
        name: "closed-local-port",
        host: "127.0.0.1",
        port: unused_port(),
        use_tls: false,
        nickname: "retry_test"
      })

    session = start_supervised!({Session, connection})
    monitor_ref = Process.monitor(session)

    assert_receive {:DOWN, ^monitor_ref, :process, ^session, :normal}, 5_000

    Enum.each(1..5, fn attempt ->
      assert_receive {:retry_attempt, ^attempt, connection_id}
      assert connection_id == connection.id
    end)

    updated = Repo.reload(connection)
    assert updated.status == "errored"
    assert updated.desired_state == "paused"

    messages =
      Message
      |> where([message], message.server_connection_id == ^connection.id)
      |> order_by([message], asc: message.id)
      |> Repo.all()

    assert Enum.count(messages, &String.starts_with?(&1.body, "Connecting to")) == 1
    assert Enum.count(messages, &String.starts_with?(&1.body, "Connection lost")) == 1

    assert [issue_message] =
             Enum.filter(messages, &is_map(&1.metadata["connection_issue"]))

    assert issue_message.metadata["connection_issue"]["code"] == "connection_failed"
    assert issue_message.metadata["connection_issue"]["edit_focus"] == "connection"
  end

  defp unused_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, {_address, port}} = :inet.sockname(socket)
    :ok = :gen_tcp.close(socket)
    port
  end
end
