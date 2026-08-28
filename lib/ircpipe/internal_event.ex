defmodule Ircpipe.InternalEvent do
  @moduledoc false

  alias Ircpipe.EngineClient.Contract

  @version 1
  @keys MapSet.new([:data, :event_id, :occurred_at, :type, :user_id, :version])
  @types ~w(
    buffer_joined
    buffer_left
    buffer_read
    connection_status_changed
    direct_message_thread_changed
    direct_message_thread_closed
    message_committed
    notification_committed
    presence_changed
    presence_synchronized
  )

  def version, do: @version
  def types, do: @types

  def new(type, user_id, data, opts \\ []) do
    occurred_at =
      normalize_occurred_at(Keyword.get(opts, :occurred_at, DateTime.utc_now(:second)))

    event = %{
      version: @version,
      event_id: Keyword.get_lazy(opts, :event_id, fn -> generate_event_id(type, occurred_at) end),
      type: to_string(type),
      occurred_at: occurred_at,
      user_id: user_id,
      data: data
    }

    case validate(event) do
      :ok -> {:ok, event}
      {:error, reason} -> {:error, reason}
    end
  end

  def new!(type, user_id, data, opts \\ []) do
    case new(type, user_id, data, opts) do
      {:ok, event} -> event
      {:error, reason} -> raise ArgumentError, "invalid internal event: #{inspect(reason)}"
    end
  end

  def validate(%{version: @version} = event) do
    with true <- MapSet.new(Map.keys(event)) == @keys,
         true <- event.type in @types,
         true <- Contract.valid_request_id?(event.event_id),
         true <- is_integer(event.user_id) and event.user_id > 0,
         true <- valid_occurred_at?(event.occurred_at),
         true <- is_map(event.data) and Contract.plain_term?(event.data) do
      :ok
    else
      _invalid -> {:error, :invalid_event}
    end
  end

  def validate(_event), do: {:error, :invalid_event}

  defp normalize_occurred_at(%DateTime{} = occurred_at), do: DateTime.to_iso8601(occurred_at)
  defp normalize_occurred_at(occurred_at) when is_binary(occurred_at), do: occurred_at
  defp normalize_occurred_at(_occurred_at), do: nil

  defp valid_occurred_at?(occurred_at) when is_binary(occurred_at) do
    match?({:ok, _datetime, 0}, DateTime.from_iso8601(occurred_at))
  end

  defp valid_occurred_at?(_occurred_at), do: false

  defp generate_event_id(type, occurred_at) do
    random = :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
    "internal:#{type}:#{occurred_at}:#{random}"
  end
end
