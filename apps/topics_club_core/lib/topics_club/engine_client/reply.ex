defmodule TopicsClub.EngineClient.Reply do
  @moduledoc false

  alias TopicsClub.EngineClient.Contract

  @errors [
    :engine_unavailable,
    :internal_error,
    :invalid_request,
    :invalid_response,
    :invalid_state,
    :not_connected,
    :timeout,
    :unauthorized,
    :unsupported_operation,
    :unsupported_version
  ]

  @ok_keys MapSet.new([:data, :operation, :request_id, :status, :version])
  @error_keys MapSet.new([:details, :error, :operation, :request_id, :status, :version])

  def errors, do: @errors

  def ok(request, data) do
    if Contract.plain_term?(data) do
      base(request, :ok)
      |> Map.put(:data, data)
    else
      error(request, :internal_error, %{reason: "non_plain_reply"})
    end
  end

  def error(request, error, details \\ %{})

  def error(request, error, details)
      when error in @errors and is_map(details) do
    details = if Contract.plain_term?(details), do: details, else: %{}

    request
    |> base(:error)
    |> Map.put(:error, error)
    |> Map.put(:details, details)
  end

  def error(request, _error, _details) do
    error(request, :internal_error, %{reason: "unstable_error"})
  end

  def decode(reply, request) when is_map(reply) do
    case reply do
      %{status: :ok, data: data} ->
        if valid_base?(reply, request, @ok_keys) and Contract.plain_term?(data) do
          {:ok, data}
        else
          invalid_response()
        end

      %{status: :error, error: error, details: details} ->
        if valid_base?(reply, request, @error_keys) and error in @errors and is_map(details) and
             Contract.plain_term?(details) do
          {:error, %{code: error, details: details}}
        else
          invalid_response()
        end

      _invalid ->
        invalid_response()
    end
  end

  def decode(_reply, _request), do: invalid_response()

  defp base(request, status) do
    %{
      version: Contract.version(),
      operation: safe_operation(request),
      request_id: safe_request_id(request),
      status: status
    }
  end

  defp valid_base?(reply, request, expected_keys) do
    MapSet.new(Map.keys(reply)) == expected_keys and
      reply.version == Contract.version() and
      reply.operation == Map.get(request, :operation) and
      reply.request_id == Map.get(request, :request_id)
  end

  defp safe_operation(%{operation: operation}) when is_atom(operation), do: operation
  defp safe_operation(_request), do: nil

  defp safe_request_id(%{request_id: request_id}) do
    if Contract.valid_request_id?(request_id), do: request_id
  end

  defp safe_request_id(_request), do: nil

  defp invalid_response, do: {:error, %{code: :invalid_response, details: %{}}}
end
