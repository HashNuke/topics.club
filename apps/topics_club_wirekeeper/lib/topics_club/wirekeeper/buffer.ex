defmodule TopicsClub.Wirekeeper.Buffer do
  @moduledoc false

  @default_max_records 1_000
  @default_max_bytes 1_048_576
  @default_max_in_flight 64

  defstruct [
    :table,
    :max_records,
    :max_bytes,
    :max_in_flight,
    next_sequence: 1,
    records: 0,
    bytes: 0,
    dropped_records: 0,
    dropped_bytes: 0
  ]

  @type sequence :: pos_integer()
  @type record :: {sequence(), binary()}
  @type overflow :: %{records: non_neg_integer(), bytes: non_neg_integer()}

  @type t :: %__MODULE__{
          table: :ets.tid(),
          max_records: pos_integer(),
          max_bytes: pos_integer(),
          max_in_flight: pos_integer(),
          next_sequence: sequence(),
          records: non_neg_integer(),
          bytes: non_neg_integer(),
          dropped_records: non_neg_integer(),
          dropped_bytes: non_neg_integer()
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, :invalid_buffer_options}
  def new(opts) when is_list(opts) do
    max_records = Keyword.get(opts, :max_records, @default_max_records)
    max_bytes = Keyword.get(opts, :max_bytes, @default_max_bytes)
    max_in_flight = Keyword.get(opts, :max_in_flight, @default_max_in_flight)

    if positive_integer?(max_records) and positive_integer?(max_bytes) and
         positive_integer?(max_in_flight) do
      table = :ets.new(__MODULE__, [:ordered_set, :private])

      {:ok,
       %__MODULE__{
         table: table,
         max_records: max_records,
         max_bytes: max_bytes,
         max_in_flight: max_in_flight
       }}
    else
      {:error, :invalid_buffer_options}
    end
  end

  def new(_opts), do: {:error, :invalid_buffer_options}

  @spec push(t(), binary()) :: {t(), sequence(), overflow()}
  def push(%__MODULE__{} = buffer, payload) when is_binary(payload) do
    sequence = buffer.next_sequence
    buffer = %{buffer | next_sequence: sequence + 1}

    if byte_size(payload) > buffer.max_bytes do
      overflow = %{records: 1, bytes: byte_size(payload)}
      {count_drop(buffer, overflow), sequence, overflow}
    else
      true = :ets.insert(buffer.table, {sequence, payload})

      buffer = %{
        buffer
        | records: buffer.records + 1,
          bytes: buffer.bytes + byte_size(payload)
      }

      {buffer, overflow} = evict_until_bounded(buffer, %{records: 0, bytes: 0})
      {buffer, sequence, overflow}
    end
  end

  @spec records(t()) :: [record()]
  def records(%__MODULE__{} = buffer) do
    collect_records(buffer.table, :ets.first(buffer.table), [])
  end

  @spec delete_through(t(), sequence()) :: t()
  def delete_through(%__MODULE__{} = buffer, sequence) when is_integer(sequence) do
    delete_through(buffer, :ets.first(buffer.table), sequence)
  end

  @spec info(t()) :: %{
          buffered_records: non_neg_integer(),
          buffered_bytes: non_neg_integer(),
          dropped_records: non_neg_integer(),
          dropped_bytes: non_neg_integer()
        }
  def info(%__MODULE__{} = buffer) do
    %{
      buffered_records: buffer.records,
      buffered_bytes: buffer.bytes,
      dropped_records: buffer.dropped_records,
      dropped_bytes: buffer.dropped_bytes
    }
  end

  @spec reset_drop_counters(t()) :: t()
  def reset_drop_counters(%__MODULE__{} = buffer) do
    %{buffer | dropped_records: 0, dropped_bytes: 0}
  end

  defp evict_until_bounded(buffer, overflow)
       when buffer.records > buffer.max_records or buffer.bytes > buffer.max_bytes do
    sequence = :ets.first(buffer.table)
    [{^sequence, payload}] = :ets.lookup(buffer.table, sequence)
    true = :ets.delete(buffer.table, sequence)
    payload_bytes = byte_size(payload)

    buffer = %{
      buffer
      | records: buffer.records - 1,
        bytes: buffer.bytes - payload_bytes
    }

    overflow = %{records: overflow.records + 1, bytes: overflow.bytes + payload_bytes}
    evict_until_bounded(buffer, overflow)
  end

  defp evict_until_bounded(buffer, overflow), do: {count_drop(buffer, overflow), overflow}

  defp count_drop(buffer, %{records: records, bytes: bytes}) do
    %{
      buffer
      | dropped_records: buffer.dropped_records + records,
        dropped_bytes: buffer.dropped_bytes + bytes
    }
  end

  defp collect_records(_table, :"$end_of_table", records), do: Enum.reverse(records)

  defp collect_records(table, sequence, records) do
    [{^sequence, payload}] = :ets.lookup(table, sequence)
    collect_records(table, :ets.next(table, sequence), [{sequence, payload} | records])
  end

  defp delete_through(buffer, :"$end_of_table", _sequence), do: buffer

  defp delete_through(buffer, current, sequence) when current <= sequence do
    [{^current, payload}] = :ets.lookup(buffer.table, current)
    next = :ets.next(buffer.table, current)
    true = :ets.delete(buffer.table, current)

    buffer = %{
      buffer
      | records: buffer.records - 1,
        bytes: buffer.bytes - byte_size(payload)
    }

    delete_through(buffer, next, sequence)
  end

  defp delete_through(buffer, _current, _sequence), do: buffer

  defp positive_integer?(value), do: is_integer(value) and value > 0
end
