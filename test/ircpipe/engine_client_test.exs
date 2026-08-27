defmodule Ircpipe.EngineClientTest do
  use ExUnit.Case, async: false

  alias Ircpipe.EngineClient
  alias Ircpipe.EngineClient.Discovery

  setup do
    previous_adapter = Application.get_env(:ircpipe, :engine_client_adapter)
    previous_test_pid = Application.get_env(:ircpipe, :engine_client_test_pid)
    previous_test_reply = Application.get_env(:ircpipe, :engine_client_test_reply)

    Application.put_env(:ircpipe, :engine_client_adapter, Ircpipe.EngineClientTestAdapter)
    Application.put_env(:ircpipe, :engine_client_test_pid, self())
    Application.delete_env(:ircpipe, :engine_client_test_reply)

    on_exit(fn ->
      restore_env(:engine_client_adapter, previous_adapter)
      restore_env(:engine_client_test_pid, previous_test_pid)
      restore_env(:engine_client_test_reply, previous_test_reply)
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
    Application.put_env(:ircpipe, :engine_client_test_reply, :malformed)

    assert {:error, %{code: :invalid_response}} =
             EngineClient.connection_info(1, 2)
  end

  test "emits telemetry with operation, outcome, timeout, retry policy, and request ID" do
    handler_id = "engine-client-test-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:ircpipe, :engine_client, :request],
        fn event, measurements, metadata, test_pid ->
          send(test_pid, {:engine_client_telemetry, event, measurements, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, %{accepted: true}} =
             EngineClient.connection_statuses(1, [2], request_id: "request-telemetry")

    assert_receive {:engine_client_telemetry, [:ircpipe, :engine_client, :request],
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

    assert direct_child_pid(Ircpipe.EngineSupervisor, Ircpipe.Engine.Marker) == marker
  end

  defp direct_child_pid(supervisor, child_id) do
    supervisor
    |> Supervisor.which_children()
    |> Enum.find_value(fn
      {^child_id, pid, _type, _modules} -> pid
      _child -> nil
    end)
  end

  defp restore_env(key, nil), do: Application.delete_env(:ircpipe, key)
  defp restore_env(key, value), do: Application.put_env(:ircpipe, key, value)
end
