defmodule TopicsClub.Wirekeeper.CheckpointTest do
  use ExUnit.Case, async: false

  alias TopicsClub.Wirekeeper
  alias TopicsClub.Wirekeeper.TestTcpServer

  test "retains a bounded secret-free consumer checkpoint across attachments" do
    {server, key, opened} = open_connection()
    on_exit(fn -> Wirekeeper.close(key, opened.generation) end)

    assert_receive {:wirekeeper_test_server, :accepted, ^server, 1}
    assert {:ok, %{checkpoint: nil}} = Wirekeeper.attach(key, opened.generation)

    checkpoint = %{
      current_nick: "keeper",
      active_caps: ["batch", "server-time"],
      isupport: %{"CASEMAPPING" => "rfc1459", "CHANTYPES" => "#&"}
    }

    assert :ok = Wirekeeper.put_checkpoint(key, opened.generation, checkpoint)
    assert :ok = Wirekeeper.detach(key, opened.generation)
    assert {:ok, %{checkpoint: ^checkpoint}} = Wirekeeper.attach(key, opened.generation)

    assert {:ok, info} = Wirekeeper.info(key)
    refute Map.has_key?(info, :checkpoint)
  end

  test "only the attached generation and consumer may replace the checkpoint" do
    {_server, key, opened} = open_connection()
    on_exit(fn -> Wirekeeper.close(key, opened.generation) end)

    checkpoint = %{current_nick: "keeper"}
    stale_generation = String.duplicate("0", byte_size(opened.generation))

    assert {:error, :not_attached} =
             Wirekeeper.put_checkpoint(key, opened.generation, checkpoint)

    assert {:ok, _summary} = Wirekeeper.attach(key, opened.generation)

    assert {:error, :stale_generation} =
             Wirekeeper.put_checkpoint(key, stale_generation, checkpoint)

    other_consumer = start_supervised!({Task, fn -> receive do: (:stop -> :ok) end})

    assert {:error, :not_attached} =
             Wirekeeper.put_checkpoint(key, opened.generation, checkpoint, other_consumer)

    assert :ok = Wirekeeper.put_checkpoint(key, opened.generation, checkpoint)
    assert {:ok, %{checkpoint: ^checkpoint}} = Wirekeeper.attach(key, opened.generation)
  end

  test "rejects executable, process-bound, and oversized checkpoint data" do
    {_server, key, opened} = open_connection(checkpoint_max_bytes: 128)
    on_exit(fn -> Wirekeeper.close(key, opened.generation) end)

    assert {:ok, _summary} = Wirekeeper.attach(key, opened.generation)

    for invalid <- [self(), make_ref(), fn -> :ok end, %{pid: self()}, %{tuple: {:ok, 1}}] do
      assert {:error, :invalid_checkpoint} =
               Wirekeeper.put_checkpoint(key, opened.generation, invalid)
    end

    oversized = %{payload: String.duplicate("x", 256)}

    assert {:error, :checkpoint_too_large} =
             Wirekeeper.put_checkpoint(key, opened.generation, oversized)

    assert {:ok, %{checkpoint: nil}} = Wirekeeper.attach(key, opened.generation)
  end

  test "copies sub-binaries instead of retaining their larger source" do
    {_server, key, opened} = open_connection(checkpoint_max_bytes: 1_024)
    on_exit(fn -> Wirekeeper.close(key, opened.generation) end)

    assert {:ok, _summary} = Wirekeeper.attach(key, opened.generation)

    source = :binary.copy(String.duplicate("x", 127) <> "wanted", 10_000)
    payload = binary_part(source, 0, 127)
    assert :binary.referenced_byte_size(payload) == byte_size(source)

    assert :ok = Wirekeeper.put_checkpoint(key, opened.generation, %{payload: payload})
    assert :ok = Wirekeeper.detach(key, opened.generation)

    assert {:ok, %{checkpoint: %{payload: retained}}} =
             Wirekeeper.attach(key, opened.generation)

    assert retained == payload
    assert :binary.referenced_byte_size(retained) <= 1_024
  end

  test "atomically stores a checkpoint and cumulatively acknowledges its record" do
    {server, key, opened} = open_connection()
    on_exit(fn -> Wirekeeper.close(key, opened.generation) end)

    assert_receive {:wirekeeper_test_server, :accepted, ^server, 1}
    assert {:ok, _summary} = Wirekeeper.attach(key, opened.generation)

    assert :ok = TestTcpServer.send_data(server, "first\r\n")

    assert_receive {:topics_club_wirekeeper,
                    {:data, %{sequence: first_sequence, payload: "first\r\n"}}}

    assert :ok = TestTcpServer.send_data(server, "second\r\n")

    assert_receive {:topics_club_wirekeeper,
                    {:data, %{sequence: second_sequence, payload: "second\r\n"}}}

    checkpoint = %{version: 1, payload: "after-first"}

    assert :ok =
             Wirekeeper.ack_with_checkpoint(
               key,
               opened.generation,
               first_sequence,
               checkpoint
             )

    assert :ok = Wirekeeper.detach(key, opened.generation)

    assert {:ok, %{checkpoint: ^checkpoint, replayed_records: 1}} =
             Wirekeeper.attach(key, opened.generation)

    assert_receive {:topics_club_wirekeeper,
                    {:data, %{sequence: ^second_sequence, payload: "second\r\n"}}}
  end

  test "checkpoint validation failure leaves the record and prior checkpoint untouched" do
    {server, key, opened} = open_connection(checkpoint_max_bytes: 128)
    on_exit(fn -> Wirekeeper.close(key, opened.generation) end)

    assert_receive {:wirekeeper_test_server, :accepted, ^server, 1}
    assert {:ok, _summary} = Wirekeeper.attach(key, opened.generation)
    assert :ok = Wirekeeper.put_checkpoint(key, opened.generation, %{version: 1})
    assert :ok = TestTcpServer.send_data(server, "retained\r\n")

    assert_receive {:topics_club_wirekeeper,
                    {:data, %{sequence: sequence, payload: "retained\r\n"}}}

    oversized = %{payload: String.duplicate("x", 256)}

    assert {:error, :checkpoint_too_large} =
             Wirekeeper.ack_with_checkpoint(key, opened.generation, sequence, oversized)

    assert :ok = Wirekeeper.detach(key, opened.generation)

    assert {:ok, %{checkpoint: %{version: 1}, replayed_records: 1}} =
             Wirekeeper.attach(key, opened.generation)

    assert_receive {:topics_club_wirekeeper,
                    {:data, %{sequence: ^sequence, payload: "retained\r\n"}}}
  end

  test "an idempotent retry cannot roll a newer checkpoint backward" do
    {server, key, opened} = open_connection()
    on_exit(fn -> Wirekeeper.close(key, opened.generation) end)

    assert_receive {:wirekeeper_test_server, :accepted, ^server, 1}
    assert {:ok, _summary} = Wirekeeper.attach(key, opened.generation)
    assert :ok = TestTcpServer.send_data(server, "one\r\n")

    assert_receive {:topics_club_wirekeeper, {:data, %{sequence: first_sequence}}}
    assert :ok = TestTcpServer.send_data(server, "two\r\n")
    assert_receive {:topics_club_wirekeeper, {:data, %{sequence: second_sequence}}}

    assert :ok =
             Wirekeeper.ack_with_checkpoint(
               key,
               opened.generation,
               first_sequence,
               %{position: 1}
             )

    assert :ok =
             Wirekeeper.ack_with_checkpoint(
               key,
               opened.generation,
               second_sequence,
               %{position: 2}
             )

    assert :ok =
             Wirekeeper.ack_with_checkpoint(
               key,
               opened.generation,
               first_sequence,
               %{position: 1}
             )

    assert :ok = Wirekeeper.detach(key, opened.generation)

    assert {:ok, %{checkpoint: %{position: 2}, replayed_records: 0}} =
             Wirekeeper.attach(key, opened.generation)
  end

  test "checkpointed acknowledgement mode rejects unsafe mixed API transitions" do
    {server, key, opened} = open_connection()
    on_exit(fn -> Wirekeeper.close(key, opened.generation) end)

    assert_receive {:wirekeeper_test_server, :accepted, ^server, 1}
    assert {:ok, _summary} = Wirekeeper.attach(key, opened.generation)
    assert :ok = TestTcpServer.send_data(server, "one\r\n")
    assert_receive {:topics_club_wirekeeper, {:data, %{sequence: first_sequence}}}

    assert :ok =
             Wirekeeper.ack_with_checkpoint(
               key,
               opened.generation,
               first_sequence,
               %{position: 1}
             )

    assert :ok = TestTcpServer.send_data(server, "two\r\n")
    assert_receive {:topics_club_wirekeeper, {:data, %{sequence: second_sequence}}}

    assert {:error, :checkpoint_required} =
             Wirekeeper.ack(key, opened.generation, second_sequence)

    assert {:error, :checkpoint_ack_required} =
             Wirekeeper.put_checkpoint(key, opened.generation, %{position: 2})

    assert :ok = Wirekeeper.detach(key, opened.generation)

    assert {:ok, %{checkpoint: %{position: 1}, replayed_records: 1}} =
             Wirekeeper.attach(key, opened.generation)

    assert_receive {:topics_club_wirekeeper,
                    {:data, %{sequence: ^second_sequence, payload: "two\r\n"}}}
  end

  test "cannot retroactively pair a checkpoint with a record deleted by a plain ACK" do
    {server, key, opened} = open_connection()
    on_exit(fn -> Wirekeeper.close(key, opened.generation) end)

    assert_receive {:wirekeeper_test_server, :accepted, ^server, 1}
    assert {:ok, _summary} = Wirekeeper.attach(key, opened.generation)
    assert :ok = TestTcpServer.send_data(server, "plain\r\n")
    assert_receive {:topics_club_wirekeeper, {:data, %{sequence: sequence}}}
    assert :ok = Wirekeeper.ack(key, opened.generation, sequence)

    assert {:error, :checkpoint_not_recorded} =
             Wirekeeper.ack_with_checkpoint(
               key,
               opened.generation,
               sequence,
               %{position: sequence}
             )
  end

  test "validates checkpointed ACK authorization, sequence, and shape before changing state" do
    {server, key, opened} = open_connection()
    on_exit(fn -> Wirekeeper.close(key, opened.generation) end)
    assert_receive {:wirekeeper_test_server, :accepted, ^server, 1}

    stale_generation = String.duplicate("0", byte_size(opened.generation))
    checkpoint = %{position: 1}

    assert {:error, :not_attached} =
             Wirekeeper.ack_with_checkpoint(key, opened.generation, 1, checkpoint)

    assert {:ok, _summary} = Wirekeeper.attach(key, opened.generation)

    other_consumer = start_supervised!({Task, fn -> receive do: (:stop -> :ok) end})

    assert {:error, :stale_generation} =
             Wirekeeper.ack_with_checkpoint(key, stale_generation, 1, checkpoint)

    assert {:error, :not_attached} =
             Wirekeeper.ack_with_checkpoint(
               key,
               opened.generation,
               1,
               checkpoint,
               other_consumer
             )

    assert {:error, :invalid_ack} =
             Wirekeeper.ack_with_checkpoint(key, opened.generation, 0, checkpoint)

    assert {:error, :invalid_ack} =
             Wirekeeper.ack_with_checkpoint(key, opened.generation, 100, checkpoint)

    assert :ok = TestTcpServer.send_data(server, "record\r\n")
    assert_receive {:topics_club_wirekeeper, {:data, %{sequence: sequence}}}

    assert {:error, :invalid_checkpoint} =
             Wirekeeper.ack_with_checkpoint(
               key,
               opened.generation,
               sequence,
               %{tuple: {:not, :plain}}
             )

    assert :ok = Wirekeeper.detach(key, opened.generation)

    assert {:ok, %{checkpoint: nil, replayed_records: 1}} =
             Wirekeeper.attach(key, opened.generation)
  end

  test "checkpointed ACK releases delivery credit" do
    {server, key, opened} = open_connection(buffer: [max_in_flight: 1])
    on_exit(fn -> Wirekeeper.close(key, opened.generation) end)

    assert_receive {:wirekeeper_test_server, :accepted, ^server, 1}
    assert {:ok, _summary} = Wirekeeper.attach(key, opened.generation)
    assert :ok = TestTcpServer.send_data(server, "one\r\n")
    assert_receive {:topics_club_wirekeeper, {:data, %{sequence: first_sequence}}}
    assert :ok = TestTcpServer.send_data(server, "two\r\n")
    refute_receive {:topics_club_wirekeeper, {:data, %{payload: "two\r\n"}}}, 50

    assert :ok =
             Wirekeeper.ack_with_checkpoint(
               key,
               opened.generation,
               first_sequence,
               %{position: 1}
             )

    assert_receive {:topics_club_wirekeeper,
                    {:data, %{sequence: second_sequence, payload: "two\r\n"}}}

    assert second_sequence > first_sequence
  end

  defp open_connection(opts \\ []) do
    server = start_supervised!({TestTcpServer, self()})
    key = "checkpoint-#{System.unique_integer([:positive, :monotonic])}"

    assert {:ok, opened} =
             Wirekeeper.open(
               key,
               {:tcp, host: "127.0.0.1", port: TestTcpServer.port(server)},
               opts
             )

    {server, key, opened}
  end
end
