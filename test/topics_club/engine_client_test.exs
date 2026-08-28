defmodule TopicsClub.EngineClientTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias TopicsClub.EngineClient
  alias TopicsClub.EngineClient.Discovery

  setup do
    previous_adapter = Application.get_env(:topics_club_core, :engine_client_adapter)
    previous_test_pid = Application.get_env(:topics_club_core, :engine_client_test_pid)
    previous_test_reply = Application.get_env(:topics_club_core, :engine_client_test_reply)
    previous_local_api_module = Application.get_env(:topics_club_engine, :engine_local_api_module)

    Application.put_env(
      :topics_club_core,
      :engine_client_adapter,
      TopicsClub.EngineClientTestAdapter
    )

    Application.put_env(:topics_club_core, :engine_client_test_pid, self())
    Application.delete_env(:topics_club_core, :engine_client_test_reply)

    on_exit(fn ->
      restore_core_env(:engine_client_adapter, previous_adapter)
      restore_core_env(:engine_client_test_pid, previous_test_pid)
      restore_core_env(:engine_client_test_reply, previous_test_reply)
      restore_engine_env(:engine_local_api_module, previous_local_api_module)
    end)

    :ok
  end

  test "dispatches a generated request through the configured adapter" do
    assert {:ok, %{accepted: true}} =
             EngineClient.join_channel(1, 2, "#elixir", request_id: "request-1")

    assert_receive {:engine_client_request, request, 15_000}
    assert request.operation == :join_channel
    assert request.request_id == "request-1"
    assert request.payload == %{channel: "#elixir"}
  end

  test "rejects invalid requests before invoking the adapter" do
    assert {:error, %{code: :invalid_request}} =
             EngineClient.send_channel_message(1, 2, 3, " ")

    refute_receive {:engine_client_request, _request, _timeout}
  end

  test "normalizes malformed adapter replies" do
    Application.put_env(:topics_club_core, :engine_client_test_reply, :malformed)

    assert {:error, %{code: :invalid_response}} =
             EngineClient.connection_info(1, 2)
  end

  test "emits telemetry with operation, outcome, timeout, retry policy, and request ID" do
    handler_id = "engine-client-test-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:topics_club, :engine_client, :request],
        fn event, measurements, metadata, test_pid ->
          send(test_pid, {:engine_client_telemetry, event, measurements, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, %{accepted: true}} =
             EngineClient.connection_statuses(1, [2], request_id: "request-telemetry")

    assert_receive {:engine_client_telemetry, [:topics_club, :engine_client, :request],
                    %{duration: duration}, metadata}

    assert is_integer(duration)
    assert duration >= 0
    assert metadata.operation == :connection_statuses
    assert metadata.result == :ok
    assert metadata.timeout == 5_000
    assert metadata.retry == :safe
    assert metadata.request_id == "request-telemetry"
  end

  test "the engine marker identifies the local engine without handling requests" do
    assert {:ok, marker} = Discovery.whereis()
    assert node(marker) == node()
    assert {:ok, current_node} = Discovery.engine_node()
    assert current_node == node()

    assert direct_child_pid(TopicsClub.EngineSupervisor, TopicsClub.Engine.Marker) == marker
  end

  test "the local adapter enforces the operation timeout" do
    Application.put_env(:topics_club_core, :engine_client_adapter, TopicsClub.Engine.LocalAdapter)

    Application.put_env(
      :topics_club_engine,
      :engine_local_api_module,
      TopicsClub.BlockedEngineAPI
    )

    log =
      capture_log(fn ->
        assert {:error, %{code: :timeout, details: %{}}} =
                 EngineClient.connection_info(1, 2,
                   timeout: 10,
                   request_id: "timeout-request"
                 )
      end)

    assert log =~ "event=engine_rpc_timeout"
    assert log =~ "operation=connection_info"
    assert log =~ "request_id=timeout-request"
    assert log =~ "timeout_ms=10"
  end

  defp direct_child_pid(supervisor, child_id) do
    supervisor
    |> Supervisor.which_children()
    |> Enum.find_value(fn
      {^child_id, pid, _type, _modules} -> pid
      _child -> nil
    end)
  end

  defp restore_core_env(key, nil), do: Application.delete_env(:topics_club_core, key)
  defp restore_core_env(key, value), do: Application.put_env(:topics_club_core, key, value)

  defp restore_engine_env(key, nil), do: Application.delete_env(:topics_club_engine, key)
  defp restore_engine_env(key, value), do: Application.put_env(:topics_club_engine, key, value)
end
