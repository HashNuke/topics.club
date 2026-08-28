defmodule TopicsClub.Irc.Session.EventRecorderTest do
  use TopicsClub.DataCase, async: true

  import ExUnit.CaptureLog

  alias TopicsClub.AccountsFixtures
  alias TopicsClub.Chat
  alias TopicsClub.Chat.{Connections, MessageHistory, ServerConnection, SystemMessages}
  alias TopicsClub.Irc.Session.EventRecorder

  test "records IRC errors in an existing channel buffer" do
    user = AccountsFixtures.user_fixture()
    connection = connection_fixture(user)
    assert {:ok, membership} = Chat.join_channel(user, connection, "#elixir")

    assert {:ok, message} =
             EventRecorder.irc_error(
               %{connection: connection, active_casemapping: :ascii},
               %{target: "#Elixir", reason: "Cannot join channel"}
             )

    assert message.channel_membership_id == membership.id
    assert message.kind == "error"
    assert message.body == "Cannot join channel"
  end

  test "falls back to the server buffer when an IRC error names an unknown channel" do
    user = AccountsFixtures.user_fixture()
    connection = connection_fixture(user)

    assert {:ok, _message} =
             EventRecorder.irc_error(
               %{connection: connection, active_casemapping: :ascii},
               %{target: "#missing", code: 403}
             )

    assert [message] = MessageHistory.list_buffer_messages(user, "server:#{connection.id}")
    assert message.channel_membership_id == nil
    assert message.kind == "error"
    assert message.body == "IRC error 403."
  end

  test "channel recording reports a missing membership explicitly" do
    user = AccountsFixtures.user_fixture()
    connection = connection_fixture(user)

    assert_raise Ecto.NoResultsError, fn ->
      SystemMessages.record(
        connection,
        "#missing",
        "error",
        nil,
        "Cannot join channel"
      )
    end
  end

  test "does not swallow unrelated malformed-state map errors" do
    assert_raise BadMapError, fn ->
      EventRecorder.irc_error([], %{target: "#missing", code: 403})
    end
  end

  test "reports a recoverable persistence failure without stopping the IRC caller" do
    telemetry_id = "event-recorder-failure-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        telemetry_id,
        [:topics_club, :irc, :ingestion, :failure],
        fn event, measurements, metadata, test_pid ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(telemetry_id) end)

    connection = %ServerConnection{id: -1, user_id: -1, host: "irc.invalid.test"}

    log =
      capture_log(fn ->
        assert {:ok, nil} = EventRecorder.server_line(connection, "not persisted")
      end)

    assert log =~ "event=irc_ingestion_failed"
    refute log =~ "not persisted"

    assert_receive {:telemetry, [:topics_club, :irc, :ingestion, :failure],
                    %{system_time: system_time},
                    %{
                      connection_id: -1,
                      operation: :server_line,
                      reason: Ecto.NoResultsError
                    }}

    assert is_integer(system_time)
  end

  defp connection_fixture(user) do
    assert {:ok, connection} =
             Connections.create(user, %{
               "name" => "event-recorder-#{System.unique_integer([:positive])}",
               "host" => "irc.events.test",
               "nickname" => "mira"
             })

    connection
  end
end
