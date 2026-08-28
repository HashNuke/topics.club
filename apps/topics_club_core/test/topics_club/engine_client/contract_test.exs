defmodule TopicsClub.EngineClient.ContractTest do
  use ExUnit.Case, async: true

  alias TopicsClub.EngineClient.Contract
  alias TopicsClub.EngineClient.Reply

  @requests [
    {:connection_statuses, nil, %{connection_ids: [10, 11]}},
    {:connection_info, 10, %{}},
    {:ensure_connection, 10, %{intent: "active"}},
    {:disconnect_connection, 10, %{reason: "leaving"}},
    {:delete_connection, 10, %{}},
    {:join_channel, 10, %{channel: "#elixir"}},
    {:part_channel, 10, %{membership_id: 20, reason: "leaving"}},
    {:send_channel_message, 10, %{membership_id: 20, body: "hello", kind: "message"}},
    {:send_direct_message, 10, %{thread_id: 30, body: "hello"}},
    {:execute_command, 10, %{line: "NICK aria", command_id: "command-1", buffer_id: "server:10"}},
    {:list_channels, 10, %{}}
  ]

  test "version 1 defines every initial operation with timeout and retry policy" do
    assert Contract.version() == 1
    assert Enum.sort(Enum.map(@requests, &elem(&1, 0))) == Contract.operations()

    for operation <- Contract.operations() do
      assert is_integer(Contract.timeout(operation))
      assert Contract.timeout(operation) > 0
      assert Contract.retry_policy(operation) in [:safe, :unsafe]
    end

    assert Contract.retry_policy(:send_channel_message) == :unsafe
    assert Contract.retry_policy(:delete_connection) == :unsafe
    assert Contract.retry_policy(:connection_statuses) == :safe
  end

  test "constructs valid scalar-only envelopes for every initial operation" do
    for {operation, connection_id, payload} <- @requests do
      assert {:ok, request} =
               Contract.new(operation, 1, connection_id, payload, request_id: "request-1")

      assert request == %{
               version: 1,
               operation: operation,
               request_id: "request-1",
               user_id: 1,
               connection_id: connection_id,
               payload: payload
             }

      assert :ok = Contract.validate(request)
      assert Contract.plain_term?(request)
    end
  end

  test "generates bounded request IDs when the caller omits one" do
    assert {:ok, first} = Contract.new(:connection_info, 1, 2)
    assert {:ok, second} = Contract.new(:connection_info, 1, 2)

    assert first.request_id != second.request_id
    assert first.request_id =~ ~r/\Areq_[A-Za-z0-9_-]+\z/
    assert byte_size(first.request_id) <= 128
  end

  test "rejects unknown versions, operations, fields, and invalid IDs" do
    {:ok, request} =
      Contract.new(:connection_info, 1, 2, %{}, request_id: "request-1")

    assert {:error, :unsupported_version} = Contract.validate(%{request | version: 2})
    assert {:error, :unsupported_operation} = Contract.validate(%{request | operation: :unknown})
    assert {:error, :invalid_request} = Contract.validate(Map.put(request, :extra, true))
    assert {:error, :invalid_request} = Contract.validate(%{request | request_id: "bad id"})
    assert {:error, :invalid_request} = Contract.validate(%{request | user_id: 0})
    assert {:error, :invalid_request} = Contract.validate(%{request | connection_id: nil})
  end

  test "rejects missing, unknown, malformed, and non-plain payload values" do
    {:ok, request} =
      Contract.new(
        :send_channel_message,
        1,
        2,
        %{membership_id: 3, body: "hello", kind: "message"},
        request_id: "request-1"
      )

    assert {:error, :invalid_request} =
             Contract.validate(%{request | payload: Map.delete(request.payload, :body)})

    assert {:error, :invalid_request} =
             Contract.validate(%{request | payload: Map.put(request.payload, :extra, true)})

    assert {:error, :invalid_request} =
             Contract.validate(%{request | payload: %{request.payload | body: " "}})

    for forbidden <- [self(), make_ref(), fn -> :ok end, DateTime.utc_now()] do
      refute Contract.plain_term?(forbidden)

      assert {:error, :invalid_request} =
               Contract.validate(%{request | payload: %{request.payload | body: forbidden}})
    end
  end

  test "rejects improper lists without raising" do
    improper_list = [1 | 2]

    refute Contract.plain_term?(improper_list)

    assert {:error, :invalid_request} =
             Contract.new(
               :connection_statuses,
               1,
               nil,
               %{connection_ids: improper_list},
               request_id: "request-1"
             )
  end

  test "builds and decodes versioned success and stable error replies" do
    {:ok, request} =
      Contract.new(:connection_info, 1, 2, %{}, request_id: "request-1")

    success = Reply.ok(request, %{status: "connected"})
    assert {:ok, %{status: "connected"}} = Reply.decode(success, request)

    for error <- Reply.errors() do
      reply = Reply.error(request, error, %{source: "test"})

      assert {:error, %{code: ^error, details: %{source: "test"}}} =
               Reply.decode(reply, request)
    end
  end

  test "rejects mismatched, malformed, and non-plain replies" do
    {:ok, request} =
      Contract.new(:connection_info, 1, 2, %{}, request_id: "request-1")

    assert {:error, %{code: :invalid_response}} =
             request
             |> Reply.ok(%{status: "connected"})
             |> Map.put(:request_id, "another-request")
             |> Reply.decode(request)

    assert {:error, %{code: :invalid_response}} =
             Reply.decode(%{status: :ok, data: self()}, request)

    improper_reply = %{
      version: 1,
      operation: request.operation,
      request_id: request.request_id,
      status: :ok,
      data: %{connection_ids: [1 | 2]}
    }

    assert {:error, %{code: :invalid_response}} = Reply.decode(improper_reply, request)

    assert %{status: :error, error: :internal_error} = Reply.ok(request, %{pid: self()})
  end
end
