defmodule Ircpipe.EngineClient.Contract do
  @moduledoc false

  @version 1
  @envelope_keys MapSet.new([
                   :connection_id,
                   :operation,
                   :payload,
                   :request_id,
                   :user_id,
                   :version
                 ])
  @request_id_pattern ~r/\A[A-Za-z0-9._:-]+\z/

  @operations %{
    connection_statuses: %{
      connection?: false,
      required: %{connection_ids: {:list, :positive_integer}},
      optional: %{},
      timeout: 5_000,
      retry: :safe
    },
    connection_info: %{
      connection?: true,
      required: %{},
      optional: %{},
      timeout: 5_000,
      retry: :safe
    },
    ensure_connection: %{
      connection?: true,
      required: %{},
      optional: %{intent: {:one_of, ["active", "restore"]}},
      timeout: 15_000,
      retry: :safe
    },
    disconnect_connection: %{
      connection?: true,
      required: %{},
      optional: %{reason: :string},
      timeout: 10_000,
      retry: :safe
    },
    quiesce_connection: %{
      connection?: true,
      required: %{},
      optional: %{},
      timeout: 10_000,
      retry: :safe
    },
    join_channel: %{
      connection?: true,
      required: %{channel: :nonempty_string},
      optional: %{},
      timeout: 15_000,
      retry: :safe
    },
    part_channel: %{
      connection?: true,
      required: %{membership_id: :positive_integer},
      optional: %{reason: :string},
      timeout: 10_000,
      retry: :unsafe
    },
    send_channel_message: %{
      connection?: true,
      required: %{
        body: :nonempty_string,
        kind: {:one_of, ["action", "message"]},
        membership_id: :positive_integer
      },
      optional: %{},
      timeout: 10_000,
      retry: :unsafe
    },
    send_direct_message: %{
      connection?: true,
      required: %{body: :nonempty_string, thread_id: :positive_integer},
      optional: %{},
      timeout: 10_000,
      retry: :unsafe
    },
    execute_command: %{
      connection?: true,
      required: %{
        buffer_id: :nonempty_string,
        command_id: :nonempty_string,
        line: :nonempty_string
      },
      optional: %{},
      timeout: 15_000,
      retry: :unsafe
    },
    list_channels: %{
      connection?: true,
      required: %{},
      optional: %{},
      timeout: 12_000,
      retry: :safe
    }
  }

  def version, do: @version
  def operations, do: @operations |> Map.keys() |> Enum.sort()

  def timeout(operation) do
    case Map.fetch(@operations, operation) do
      {:ok, metadata} -> metadata.timeout
      :error -> nil
    end
  end

  def retry_policy(operation) do
    case Map.fetch(@operations, operation) do
      {:ok, metadata} -> metadata.retry
      :error -> nil
    end
  end

  def new(operation, user_id, connection_id, payload \\ %{}, opts \\ []) do
    request = %{
      version: @version,
      operation: operation,
      request_id: Keyword.get_lazy(opts, :request_id, &generate_request_id/0),
      user_id: user_id,
      connection_id: connection_id,
      payload: payload
    }

    case validate(request) do
      :ok -> {:ok, request}
      {:error, reason} -> {:error, reason}
    end
  end

  def validate(%{version: version}) when version != @version, do: {:error, :unsupported_version}

  def validate(%{version: @version, operation: operation} = request) do
    case Map.fetch(@operations, operation) do
      {:ok, metadata} -> validate_known_operation(request, metadata)
      :error -> {:error, :unsupported_operation}
    end
  end

  def validate(_request), do: {:error, :invalid_request}

  def plain_term?(value)
      when is_nil(value) or is_boolean(value) or is_integer(value) or is_float(value) or
             is_binary(value) or is_atom(value),
      do: true

  def plain_term?([]), do: true
  def plain_term?([head | tail]), do: plain_term?(head) and plain_list?(tail)

  def plain_term?(value) when is_map(value) do
    not Map.has_key?(value, :__struct__) and
      Enum.all?(value, fn {key, item} ->
        (is_atom(key) or is_binary(key)) and plain_term?(item)
      end)
  end

  def plain_term?(_value), do: false

  def valid_request_id?(request_id) when is_binary(request_id) do
    byte_size(request_id) in 1..128 and String.match?(request_id, @request_id_pattern)
  end

  def valid_request_id?(_request_id), do: false

  defp validate_known_operation(request, metadata) do
    payload = Map.get(request, :payload)

    with true <- MapSet.new(Map.keys(request)) == @envelope_keys,
         true <- valid_request_id?(Map.get(request, :request_id)),
         true <- positive_integer?(Map.get(request, :user_id)),
         true <- valid_connection_id?(Map.get(request, :connection_id), metadata.connection?),
         true <- is_map(payload) and plain_term?(payload),
         true <- valid_payload?(payload, metadata) do
      :ok
    else
      _invalid -> {:error, :invalid_request}
    end
  end

  defp valid_payload?(payload, metadata) do
    required = metadata.required
    optional = metadata.optional
    allowed_keys = Map.keys(required) ++ Map.keys(optional)

    Enum.sort(Map.keys(payload)) == Enum.sort(Enum.uniq(Map.keys(payload))) and
      Enum.all?(Map.keys(payload), &(&1 in allowed_keys)) and
      Enum.all?(required, fn {key, type} ->
        Map.has_key?(payload, key) and valid_type?(Map.get(payload, key), type)
      end) and
      Enum.all?(optional, fn {key, type} ->
        not Map.has_key?(payload, key) or valid_type?(Map.get(payload, key), type)
      end)
  end

  defp valid_type?(value, :positive_integer), do: positive_integer?(value)
  defp valid_type?(value, :string), do: is_binary(value)
  defp valid_type?(value, :nonempty_string), do: is_binary(value) and String.trim(value) != ""

  defp valid_type?(value, {:list, type}), do: valid_list_type?(value, type)
  defp valid_type?(value, {:one_of, values}), do: value in values

  defp valid_list_type?([], _type), do: true

  defp valid_list_type?([head | tail], type),
    do: valid_type?(head, type) and valid_list_type?(tail, type)

  defp valid_list_type?(_value, _type), do: false

  defp plain_list?([]), do: true
  defp plain_list?([head | tail]), do: plain_term?(head) and plain_list?(tail)
  defp plain_list?(_value), do: false

  defp valid_connection_id?(connection_id, true), do: positive_integer?(connection_id)
  defp valid_connection_id?(nil, false), do: true
  defp valid_connection_id?(_connection_id, false), do: false

  defp positive_integer?(value), do: is_integer(value) and value > 0

  defp generate_request_id do
    random = :crypto.strong_rand_bytes(18) |> Base.url_encode64(padding: false)
    "req_#{random}"
  end
end
