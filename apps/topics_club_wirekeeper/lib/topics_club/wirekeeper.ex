defmodule TopicsClub.Wirekeeper do
  @moduledoc """
  Owns long-lived upstream sockets independently from their traffic consumers.

  Connections use an opaque key and a random generation. The generation must match for every
  mutating operation, preventing a stale consumer from affecting a replacement socket. Exactly one
  consumer PID may be attached at a time; losing that process detaches it without closing the
  upstream connection. Complete adapter records remain in bounded ETS storage until cumulatively
  acknowledged, providing bounded at-least-once delivery across consumer replacement.
  """

  alias TopicsClub.Wirekeeper.{Connection, Manager}

  @snapshot_timeout 250

  @typedoc "An application-selected stable connection identifier."
  @type key :: integer() | binary()

  @typedoc "A random identifier for one opening of a connection key."
  @type generation :: binary()

  @typedoc "A supported upstream socket and its connection options."
  @type transport :: {:tcp | :tls, keyword()}

  @typedoc "A protocol adapter module and its initialization options."
  @type protocol_adapter :: {module(), keyword()}

  @typedoc "Public information about one open connection."
  @type connection_info :: %{
          key: key(),
          generation: generation(),
          transport: :tcp | :tls,
          status: :open | :closed,
          upstream_closed_reason: nil | atom() | tuple(),
          attached?: boolean(),
          acked_through: non_neg_integer(),
          buffered_records: non_neg_integer(),
          buffered_bytes: non_neg_integer(),
          in_flight_records: non_neg_integer(),
          dropped_records: non_neg_integer(),
          dropped_bytes: non_neg_integer(),
          detached_for_ms: non_neg_integer()
        }

  @typedoc "Buffered replay and overflow observed before a consumer attached."
  @type replay_summary :: %{
          key: key(),
          generation: generation(),
          delivery_guarantee: :at_least_once,
          gap?: boolean(),
          replayed_records: non_neg_integer(),
          replayed_bytes: non_neg_integer(),
          dropped_records: non_neg_integer(),
          dropped_bytes: non_neg_integer(),
          detached_for_ms: non_neg_integer()
        }

  @doc """
  Opens and begins owning one upstream connection.

  The new connection starts detached. Pass `:protocol_adapter` as `{module, options}` to customize
  inbound framing and maintenance replies. It defaults to the passthrough adapter.
  """
  @spec open(key(), transport(), keyword()) ::
          {:ok, connection_info()} | {:error, atom() | {:transport, atom()}}
  def open(key, transport, opts \\ []) do
    Manager.open(key, transport, opts)
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  @doc "Attaches one local or remote consumer process to an open generation."
  @spec attach(key(), generation(), pid()) :: {:ok, replay_summary()} | {:error, atom()}
  def attach(key, generation, consumer \\ self()) do
    with_connection(key, &Connection.attach(&1, generation, consumer))
  end

  @doc "Detaches the matching consumer without closing the upstream socket."
  @spec detach(key(), generation(), pid()) :: :ok | {:error, atom()}
  def detach(key, generation, consumer \\ self()) do
    with_connection(key, &Connection.detach(&1, generation, consumer))
  end

  @doc "Acknowledges all delivered records through `sequence` for the matching consumer."
  @spec ack(key(), generation(), pos_integer(), pid()) :: :ok | {:error, atom()}
  def ack(key, generation, sequence, consumer \\ self()) do
    with_connection(key, &Connection.ack(&1, generation, sequence, consumer))
  end

  @doc "Sends bytes to the upstream socket when the generation still matches."
  @spec send_data(key(), generation(), iodata()) :: :ok | {:error, atom() | {:transport, atom()}}
  def send_data(key, generation, data) do
    with_connection(key, &Connection.send_data(&1, generation, data))
  end

  @doc "Closes the upstream socket when the generation still matches."
  @spec close(key(), generation()) :: :ok | {:error, atom()}
  def close(key, generation) do
    with_connection(key, &Connection.close(&1, generation))
  end

  @doc "Returns information about one open connection."
  @spec info(key()) :: {:ok, connection_info()} | {:error, :not_found | :unavailable | :opening}
  def info(key) do
    with_connection(key, &Connection.info/1)
  end

  @doc "Lists all currently open and retained closed connections."
  @spec list() :: {:ok, [connection_info()]} | {:error, :unavailable}
  def list do
    with {:ok, connections} <- safe_manager_connections() do
      connections
      |> Task.async_stream(&safe_connection_info/1,
        max_concurrency: max(length(connections), 1),
        ordered: false,
        timeout: @snapshot_timeout,
        on_timeout: :kill_task
      )
      |> Enum.reduce_while({:ok, []}, fn
        {:ok, {:ok, info}}, {:ok, infos} -> {:cont, {:ok, [info | infos]}}
        _error, _infos -> {:halt, {:error, :unavailable}}
      end)
      |> case do
        {:ok, infos} -> {:ok, Enum.sort_by(infos, &inspect(&1.key))}
        {:error, :unavailable} = error -> error
      end
    end
  end

  @doc "Returns bounded aggregate connection, replay-buffer, and overflow counters."
  @spec diagnostics() ::
          {:ok,
           %{
             total_connections: non_neg_integer(),
             open_connections: non_neg_integer(),
             closed_connections: non_neg_integer(),
             attached_connections: non_neg_integer(),
             detached_connections: non_neg_integer(),
             buffered_records: non_neg_integer(),
             buffered_bytes: non_neg_integer(),
             dropped_records: non_neg_integer(),
             dropped_bytes: non_neg_integer()
           }}
          | {:error, :unavailable}
  def diagnostics do
    with {:ok, infos} <- list() do
      totals =
        Enum.reduce(
          infos,
          %{
            total_connections: length(infos),
            open_connections: 0,
            closed_connections: 0,
            attached_connections: 0,
            detached_connections: 0,
            buffered_records: 0,
            buffered_bytes: 0,
            dropped_records: 0,
            dropped_bytes: 0
          },
          fn info, totals ->
            totals
            |> Map.update!(
              if(info.status == :open, do: :open_connections, else: :closed_connections),
              &(&1 + 1)
            )
            |> Map.update!(
              if(info.attached?, do: :attached_connections, else: :detached_connections),
              &(&1 + 1)
            )
            |> Map.update!(:buffered_records, &(&1 + info.buffered_records))
            |> Map.update!(:buffered_bytes, &(&1 + info.buffered_bytes))
            |> Map.update!(:dropped_records, &(&1 + info.dropped_records))
            |> Map.update!(:dropped_bytes, &(&1 + info.dropped_bytes))
          end
        )

      {:ok, totals}
    end
  end

  defp with_connection(key, callback) do
    case safe_manager_lookup(key) do
      {:ok, connection} -> safe_connection_call(fn -> callback.(connection) end)
      {:error, _reason} = error -> error
    end
  end

  defp safe_manager_lookup(key) do
    Manager.lookup(key)
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  defp safe_manager_connections do
    {:ok, Manager.connections()}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  defp safe_connection_call(callback) do
    callback.()
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  defp safe_connection_info(connection) do
    safe_connection_call(fn -> Connection.info(connection) end)
  end
end
