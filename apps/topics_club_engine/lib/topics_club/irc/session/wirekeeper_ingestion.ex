defmodule TopicsClub.Irc.Session.WirekeeperIngestion do
  @moduledoc false

  require Logger

  alias TopicsClub.Irc.IngestionClaimReleaser

  @dispatch_active_key {__MODULE__, :dispatch_active}
  @dispatch_context_key {__MODULE__, :dispatch_context}
  @dispatch_failure_key {__MODULE__, :dispatch_failure}

  def initialize(state) do
    Map.merge(state, %{
      wirekeeper_receipts: :queue.new(),
      wirekeeper_effect_index: 0,
      wirekeeper_ingestion_failure: nil,
      wirekeeper_ingestion_retry_started?: false
    })
  end

  def enqueue(state, %{generation: generation, sequence: sequence})
      when is_binary(generation) and is_integer(sequence) and sequence > 0 do
    receipt = %{generation: generation, sequence: sequence}

    Map.update!(state, :wirekeeper_receipts, &:queue.in(receipt, &1))
  end

  def enqueue(state, _invalid), do: state

  def record_result(state, :ok), do: state
  def record_result(state, {:ok, _result}), do: state

  def record_result(state, {:error, reason}) do
    case :queue.peek(receipts(state)) do
      {:value, %{sequence: sequence}} ->
        report_failure(state.connection.id, sequence, reason)
        %{state | wirekeeper_ingestion_failure: {sequence, reason}}

      :empty ->
        report_failure(state.connection.id, nil, reason)
        state
    end
  end

  def record_result(state, unexpected),
    do: record_result(state, {:error, {:unexpected_ingestion_result, unexpected}})

  def retrying?(state), do: Map.get(state, :wirekeeper_ingestion_retry_started?, false)

  def failed?(state), do: not is_nil(Map.get(state, :wirekeeper_ingestion_failure))

  def blocked?(state), do: failed?(state) or retrying?(state)

  def failure_reason(state) do
    case Map.get(state, :wirekeeper_ingestion_failure) do
      {_sequence, reason} -> reason
      nil -> nil
    end
  end

  def mark_retry_started(state), do: %{state | wirekeeper_ingestion_retry_started?: true}

  def acknowledge(state, sequence) when is_integer(sequence) do
    case :queue.out(state.wirekeeper_receipts) do
      {{:value, %{generation: generation, sequence: ^sequence}}, remaining} ->
        release_claims(state.connection.id, generation, sequence)

        %{
          state
          | wirekeeper_receipts: remaining,
            wirekeeper_effect_index: 0
        }

      _missing_or_out_of_order ->
        state
    end
  end

  def reset(state), do: initialize(state)

  def begin_event(state, event) do
    Process.put(@dispatch_active_key, true)
    Process.delete(@dispatch_failure_key)

    context = event_context(state, event)

    Process.put(@dispatch_context_key, context)
    :ok
  end

  def finish_event(state) do
    Process.delete(@dispatch_active_key)
    context = Process.delete(@dispatch_context_key)

    state =
      case context do
        %{effect_index: effect_index} -> %{state | wirekeeper_effect_index: effect_index}
        nil -> state
      end

    case Process.delete(@dispatch_failure_key) do
      nil -> state
      reason -> record_result(state, {:error, reason})
    end
  end

  def event_failed?, do: not is_nil(Process.get(@dispatch_failure_key))

  def context_effect(effect_name) when is_binary(effect_name) do
    case Process.get(@dispatch_context_key) do
      %{generation: generation, sequence: sequence, effect_index: effect_index} = context ->
        Process.put(@dispatch_context_key, %{context | effect_index: effect_index + 1})

        %{
          generation: generation,
          sequence: sequence,
          effect_key: "#{effect_name}:#{effect_index}"
        }

      nil ->
        nil
    end
  end

  defp event_context(state, %Ircxd.Client.Event{origin: :message}) do
    case :queue.peek(receipts(state)) do
      {:value, %{generation: generation, sequence: sequence}} ->
        %{
          generation: generation,
          sequence: sequence,
          effect_index: state.wirekeeper_effect_index
        }

      :empty ->
        nil
    end
  end

  defp event_context(_state, _event), do: nil

  defp receipts(state), do: Map.get(state, :wirekeeper_receipts, :queue.new())

  defp release_claims(connection_id, generation, sequence) do
    IngestionClaimReleaser.release(connection_id, generation, sequence)
  end

  def note_failure(reason) do
    if Process.get(@dispatch_active_key) == true and
         is_nil(Process.get(@dispatch_failure_key)) do
      Process.put(@dispatch_failure_key, reason)
    end

    :ok
  end

  def observe_result(:ok), do: :ok
  def observe_result({:ok, _result} = result), do: result

  def observe_result({:error, reason} = error) do
    note_failure(reason)
    error
  end

  def observe_result(result), do: result

  defp report_failure(connection_id, sequence, reason) do
    message =
      if is_integer(sequence),
        do: "IRC delivery was not acknowledged because persistence failed",
        else: "IRC event persistence failed"

    Logger.warning(message,
      event: :irc_ingestion_failed,
      connection_id: connection_id,
      wirekeeper_sequence: sequence,
      reason: inspect(reason)
    )

    :telemetry.execute(
      [:topics_club, :irc, :ingestion, :failure],
      %{system_time: System.system_time()},
      %{connection_id: connection_id, wirekeeper_sequence: sequence, reason: reason}
    )
  end
end
