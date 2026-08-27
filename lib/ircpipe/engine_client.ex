defmodule Ircpipe.EngineClient do
  @moduledoc false

  alias Ircpipe.EngineClient.Contract
  alias Ircpipe.EngineClient.Reply

  def connection_statuses(user_id, connection_ids, opts \\ []) do
    request(:connection_statuses, user_id, nil, %{connection_ids: connection_ids}, opts)
  end

  def connection_info(user_id, connection_id, opts \\ []) do
    request(:connection_info, user_id, connection_id, %{}, opts)
  end

  def ensure_connection(user_id, connection_id, opts \\ []) do
    {intent, opts} = Keyword.pop(opts, :intent, "active")
    request(:ensure_connection, user_id, connection_id, %{intent: intent}, opts)
  end

  def disconnect_connection(user_id, connection_id, opts \\ []) do
    {reason, opts} = Keyword.pop(opts, :reason, nil)
    payload = if is_nil(reason), do: %{}, else: %{reason: reason}
    request(:disconnect_connection, user_id, connection_id, payload, opts)
  end

  def quiesce_connection(user_id, connection_id, opts \\ []) do
    request(:quiesce_connection, user_id, connection_id, %{}, opts)
  end

  def join_channel(user_id, connection_id, channel, opts \\ []) do
    request(:join_channel, user_id, connection_id, %{channel: channel}, opts)
  end

  def part_channel(user_id, connection_id, membership_id, opts \\ []) do
    {reason, opts} = Keyword.pop(opts, :reason, nil)
    payload = %{membership_id: membership_id}
    payload = if is_nil(reason), do: payload, else: Map.put(payload, :reason, reason)
    request(:part_channel, user_id, connection_id, payload, opts)
  end

  def send_channel_message(user_id, connection_id, membership_id, body, opts \\ []) do
    {kind, opts} = Keyword.pop(opts, :kind, "message")

    request(
      :send_channel_message,
      user_id,
      connection_id,
      %{membership_id: membership_id, body: body, kind: kind},
      opts
    )
  end

  def send_direct_message(user_id, connection_id, thread_id, body, opts \\ []) do
    request(
      :send_direct_message,
      user_id,
      connection_id,
      %{thread_id: thread_id, body: body},
      opts
    )
  end

  def execute_command(user_id, connection_id, line, command_id, buffer_id, opts \\ []) do
    request(
      :execute_command,
      user_id,
      connection_id,
      %{line: line, command_id: command_id, buffer_id: buffer_id},
      opts
    )
  end

  def list_channels(user_id, connection_id, opts \\ []) do
    request(:list_channels, user_id, connection_id, %{}, opts)
  end

  def request(operation, user_id, connection_id, payload, opts \\ []) do
    case Contract.new(operation, user_id, connection_id, payload, opts) do
      {:ok, request} -> invoke(request, opts)
      {:error, code} -> {:error, %{code: code, details: %{}}}
    end
  end

  defp invoke(request, opts) do
    timeout = Keyword.get(opts, :timeout, Contract.timeout(request.operation))
    started_at = System.monotonic_time()
    reply = invoke_adapter(request, timeout)
    result = Reply.decode(reply, request)

    :telemetry.execute(
      [:ircpipe, :engine_client, :request],
      %{duration: System.monotonic_time() - started_at},
      %{
        operation: request.operation,
        request_id: request.request_id,
        result: result_code(result),
        retry: Contract.retry_policy(request.operation),
        timeout: timeout
      }
    )

    result
  end

  defp invoke_adapter(request, timeout) when is_integer(timeout) and timeout > 0 do
    adapter = Application.get_env(:ircpipe, :engine_client_adapter)

    if is_atom(adapter) and Code.ensure_loaded?(adapter) and
         function_exported?(adapter, :request, 2) do
      apply(adapter, :request, [request, timeout])
    else
      Reply.error(request, :engine_unavailable)
    end
  rescue
    _exception -> Reply.error(request, :engine_unavailable)
  catch
    :exit, {:timeout, _call} -> Reply.error(request, :timeout)
    :exit, _reason -> Reply.error(request, :engine_unavailable)
  end

  defp invoke_adapter(request, _timeout), do: Reply.error(request, :invalid_request)

  defp result_code({:ok, _data}), do: :ok
  defp result_code({:error, %{code: code}}), do: code
end
