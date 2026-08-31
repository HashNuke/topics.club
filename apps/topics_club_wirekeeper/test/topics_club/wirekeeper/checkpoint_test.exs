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
