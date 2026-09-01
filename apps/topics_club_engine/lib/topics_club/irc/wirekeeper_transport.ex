defmodule TopicsClub.Irc.WirekeeperTransport do
  @moduledoc false

  @behaviour Ircxd.Client.Transport

  alias Ircxd.Client.Transport

  @wirekeeper TopicsClub.Wirekeeper
  @irc_keepalive TopicsClub.Wirekeeper.ProtocolAdapter.IrcKeepalive
  @transport_api_version 1
  @replacement_attempts 100

  @impl true
  def connect(client, _config, opts) when is_pid(client) and is_list(opts) do
    with {:ok, settings} <- settings(opts) do
      connect_monitored(client, settings)
    end
  end

  def connect(_client, _config, _opts), do: {:error, :invalid_transport_options}

  @impl true
  def send_data(handle, data) do
    with_handle(handle, fn node, key, generation, _client, _consumer ->
      call(node, :send_data, [key, generation, data])
    end)
  end

  @impl true
  def activate(_handle), do: :ok

  @impl true
  def checkpoint?(_handle), do: true

  @impl true
  def accepted(handle, receipt, checkpoint) do
    with_handle(handle, fn node, key, generation, client, consumer ->
      send(
        consumer,
        {:topics_club_wirekeeper_transport,
         {:accepted,
          %{
            node: node,
            key: key,
            generation: generation,
            client: client,
            consumer: consumer,
            receipt: receipt,
            checkpoint: checkpoint
          }}}
      )

      :ok
    end)
  end

  @impl true
  def close(handle, {:connect_rejected, _reason}) do
    with_handle(handle, fn node, key, generation, _client, _consumer ->
      with :ok <- normalize_close(call(node, :close, [key, generation])) do
        await_missing(node, key, @replacement_attempts)
      end
    end)
  end

  def close(handle, {:wirekeeper_node_down, target_node}) do
    with_handle(handle, fn node, key, generation, _client, consumer ->
      if node == target_node do
        node
        |> call(:detach, [key, generation, consumer])
        |> normalize_node_down_detach()
      else
        :ok
      end
    end)
  end

  def close(handle, _reason) do
    with_handle(handle, fn node, key, generation, _client, consumer ->
      normalize_detach(call(node, :detach, [key, generation, consumer]))
    end)
  end

  @impl true
  def handle_info(
        {:nodedown, node},
        {__MODULE__, node, _key, _generation, _client, _consumer}
      ),
      do: {:closed, {:wirekeeper_node_down, node}}

  def handle_info(
        {:nodedown, node, _info},
        {__MODULE__, node, _key, _generation, _client, _consumer}
      ),
      do: {:closed, {:wirekeeper_node_down, node}}

  def handle_info(_message, _handle), do: :unknown

  @doc false
  def deliver(
        client,
        %{key: key, generation: generation, sequence: sequence, payload: payload} = data
      )
      when is_pid(client) and is_binary(payload) do
    with {:ok, node} <- message_node(data) do
      Transport.deliver(client, handle(node, key, generation, client, self()), sequence, payload)
    end
  end

  def deliver(_client, _payload), do: {:error, :invalid_wirekeeper_message}

  @doc false
  def acknowledge(%{checkpoint: nil} = accepted) do
    call(
      accepted.node,
      :ack,
      [accepted.key, accepted.generation, accepted.receipt, accepted.consumer]
    )
  end

  def acknowledge(%{checkpoint: {:unavailable, reason}} = accepted) do
    _result = call(accepted.node, :close, [accepted.key, accepted.generation])
    {:error, {:checkpoint_unavailable, reason}}
  end

  def acknowledge(%{checkpoint: checkpoint} = accepted) when is_map(checkpoint) do
    call(
      accepted.node,
      :ack_with_checkpoint,
      [
        accepted.key,
        accepted.generation,
        accepted.receipt,
        checkpoint,
        accepted.consumer
      ]
    )
  end

  def acknowledge(_accepted), do: {:error, :invalid_acceptance}

  @doc false
  def acceptance_failed(%{client: client} = accepted, reason) when is_pid(client) do
    _result = call(accepted.node, :close, [accepted.key, accepted.generation])

    Transport.closed(
      client,
      handle(
        accepted.node,
        accepted.key,
        accepted.generation,
        client,
        accepted.consumer
      ),
      {:wirekeeper_ack_failed, reason}
    )
  end

  @doc false
  def upstream_closed(client, %{key: key, generation: generation, reason: reason} = data)
      when is_pid(client) do
    with {:ok, node} <- message_node(data) do
      Transport.closed(
        client,
        handle(node, key, generation, client, self()),
        {:wirekeeper_upstream_closed, reason}
      )
    end
  end

  def upstream_closed(_client, _payload), do: {:error, :invalid_wirekeeper_message}

  @doc false
  def overflowed(client, %{key: key, generation: generation} = data) when is_pid(client) do
    with {:ok, node} <- message_node(data) do
      _result = call(node, :close, [key, generation])

      Transport.closed(
        client,
        handle(node, key, generation, client, self()),
        :wirekeeper_replay_gap
      )
    end
  end

  def overflowed(_client, _payload), do: {:error, :invalid_wirekeeper_message}

  @doc false
  def health do
    case Application.get_env(:topics_club_engine, :irc_transport, :direct) do
      :direct ->
        :ok

      {:wirekeeper, target_node} when is_atom(target_node) ->
        case call(target_node, :diagnostics, []) do
          {:ok, %{transport_api_version: @transport_api_version}} -> :ok
          {:ok, %{transport_api_version: version}} -> {:error, {:incompatible, version}}
          {:ok, _diagnostics} -> {:error, :incompatible}
          {:error, reason} -> {:error, reason}
        end

      _invalid_configuration ->
        {:error, :invalid_transport_configuration}
    end
  end

  @doc false
  def close_connection(key) do
    case Application.get_env(:topics_club_engine, :irc_transport, :direct) do
      {:wirekeeper, target_node} when is_atom(target_node) ->
        case call(target_node, :info, [key]) do
          {:ok, %{generation: generation}} ->
            normalize_close(call(target_node, :close, [key, generation]))

          {:error, :not_found} ->
            :ok

          {:error, reason} ->
            {:error, reason}
        end

      :direct ->
        :ok

      _invalid_configuration ->
        {:error, :invalid_transport_configuration}
    end
  end

  @doc false
  def detach_connection(key, consumer \\ self()) when is_pid(consumer) do
    case Application.get_env(:topics_club_engine, :irc_transport, :direct) do
      {:wirekeeper, target_node} when is_atom(target_node) ->
        case call(target_node, :info, [key]) do
          {:ok, %{generation: generation}} ->
            normalize_detach(call(target_node, :detach, [key, generation, consumer]))

          {:error, :not_found} ->
            :ok

          {:error, reason} ->
            {:error, reason}
        end

      :direct ->
        :ok

      _invalid_configuration ->
        {:error, :invalid_transport_configuration}
    end
  end

  defp connect_wirekeeper(client, settings) do
    case call(settings.node, :info, [settings.key]) do
      {:ok, info} -> attach_existing(client, settings, info)
      {:error, :not_found} -> open_fresh(client, settings)
      {:error, reason} -> {:error, reason}
    end
  end

  defp connect_monitored(client, settings) do
    case connect_wirekeeper(client, settings) do
      {:ok, handle, mode} ->
        case monitor_wirekeeper(settings.node) do
          :ok ->
            {:ok, handle, mode}

          {:error, reason} ->
            _result = close(handle, {:connect_rejected, reason})
            {:error, reason}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp open_fresh(client, settings) do
    open_opts = [
      protocol_adapter: {@irc_keepalive, []},
      buffer: settings.buffer
    ]

    case call(settings.node, :open, [settings.key, settings.transport, open_opts]) do
      {:ok, opened} ->
        case call(
               settings.node,
               :attach,
               [settings.key, opened.generation, settings.consumer]
             ) do
          {:ok, _summary} ->
            {:ok,
             handle(settings.node, settings.key, opened.generation, client, settings.consumer),
             :fresh}

          attach_error ->
            _result = call(settings.node, :close, [settings.key, opened.generation])
            attach_error
        end

      open_error ->
        open_error
    end
  end

  defp attach_existing(client, settings, info) do
    with :ok <-
           normalize_detach(
             call(settings.node, :detach, [settings.key, info.generation, settings.consumer])
           ),
         {:ok, summary} <-
           call(settings.node, :attach, [settings.key, info.generation, settings.consumer]) do
      cond do
        summary.gap? ->
          replace_with_fresh(client, settings, info.generation)

        is_map(summary.checkpoint) ->
          metadata = summary |> Map.delete(:checkpoint) |> Map.put(:status, info.status)

          {:ok, handle(settings.node, settings.key, info.generation, client, settings.consumer),
           {:resumed, summary.checkpoint, metadata}}

        true ->
          replace_with_fresh(client, settings, info.generation)
      end
    end
  end

  defp replace_with_fresh(client, settings, generation) do
    _result = call(settings.node, :detach, [settings.key, generation, settings.consumer])

    with :ok <- normalize_close(call(settings.node, :close, [settings.key, generation])),
         :ok <- await_missing(settings.node, settings.key, @replacement_attempts) do
      open_fresh(client, settings)
    end
  end

  defp await_missing(_node, _key, 0), do: {:error, :replacement_timeout}

  defp await_missing(node, key, attempts) do
    case call(node, :info, [key]) do
      {:error, :not_found} ->
        :ok

      _still_present ->
        receive do
        after
          1 -> await_missing(node, key, attempts - 1)
        end
    end
  end

  defp settings(opts) do
    key = Keyword.get(opts, :key)
    node = Keyword.get(opts, :node)
    consumer = Keyword.get(opts, :consumer)
    transport = Keyword.get(opts, :transport)
    buffer = Keyword.get(opts, :buffer, [])

    if (is_integer(key) or (is_binary(key) and byte_size(key) > 0)) and is_atom(node) and
         is_pid(consumer) and valid_transport?(transport) and is_list(buffer) and
         Keyword.keyword?(buffer) do
      {:ok, %{key: key, node: node, consumer: consumer, transport: transport, buffer: buffer}}
    else
      {:error, :invalid_transport_options}
    end
  end

  defp valid_transport?({transport, opts}) when transport in [:tcp, :tls],
    do: is_list(opts) and Keyword.keyword?(opts)

  defp valid_transport?(_transport), do: false

  defp handle(node, key, generation, client, consumer),
    do: {__MODULE__, node, key, generation, client, consumer}

  defp with_handle(
         {__MODULE__, node, key, generation, client, consumer},
         callback
       ) do
    callback.(node, key, generation, client, consumer)
  end

  defp with_handle(_handle, _callback), do: {:error, :invalid_transport_handle}

  defp message_node(%{node: node}) when is_atom(node), do: {:ok, node}
  defp message_node(_message), do: {:ok, configured_node()}

  defp configured_node do
    case Application.get_env(:topics_club_engine, :irc_transport, :direct) do
      {:wirekeeper, node} when is_atom(node) -> node
      _mode -> node()
    end
  end

  defp call(target_node, function, args) do
    if target_node == node() do
      apply(@wirekeeper, function, args)
    else
      :erpc.call(target_node, @wirekeeper, function, args, 5_000)
    end
  rescue
    _exception -> {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  defp monitor_wirekeeper(target_node) when target_node == node(), do: :ok

  defp monitor_wirekeeper(target_node) do
    true = :erlang.monitor_node(target_node, true)
    :ok
  catch
    :error, :notalive -> {:error, :distribution_unavailable}
  end

  defp normalize_close(:ok), do: :ok
  defp normalize_close({:error, reason}) when reason in [:not_found, :stale_generation], do: :ok
  defp normalize_close(error), do: error

  defp normalize_detach(:ok), do: :ok

  defp normalize_detach({:error, reason})
       when reason in [:not_found, :not_attached, :stale_generation],
       do: :ok

  defp normalize_detach(error), do: error

  defp normalize_node_down_detach({:error, :unavailable}), do: :ok
  defp normalize_node_down_detach(result), do: normalize_detach(result)
end
