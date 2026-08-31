defmodule TopicsClub.Wirekeeper.BufferTest do
  use ExUnit.Case, async: true

  alias TopicsClub.Wirekeeper.Buffer

  test "copies a retained record out of a much larger source binary" do
    source = :binary.copy(String.duplicate("x", 100) <> "\n", 10_000)
    record = binary_part(source, 0, 101)
    assert :binary.referenced_byte_size(record) == byte_size(source)
    assert {:ok, buffer} = Buffer.new(max_records: 10, max_bytes: 1_024)

    {buffer, _sequence, %{records: 0, bytes: 0}} = Buffer.push(buffer, record)
    [{_sequence, retained}] = Buffer.records(buffer)

    assert byte_size(retained) == byte_size(record)
    assert :binary.referenced_byte_size(retained) == byte_size(retained)
    assert Buffer.info(buffer).buffered_bytes == byte_size(retained)
  end
end
