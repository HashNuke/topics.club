defmodule TopicsClub.Wirekeeper do
  @moduledoc """
  Owns long-lived upstream sockets independently from their traffic consumers.

  Connections use an opaque key and a random generation. The generation must match for every
  mutating operation, preventing a stale consumer from affecting a replacement socket. Exactly one
  consumer PID may be attached at a time; losing that process detaches it without closing the
  upstream connection.
  """

  alias TopicsClub.Wirekeeper.{Connection, Manager}

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
          attached?: boolean(),
          discarded_frames: non_neg_integer(),
          discarded_bytes: non_neg_integer(),
          detached_for_ms: non_neg_integer()
        }

  @typedoc "Traffic loss observed before a consumer attached."
  @type gap_summary :: %{
          key: key(),
          generation: generation(),
          gap?: boolean(),
          discarded_frames: non_neg_integer(),
          discarded_bytes: non_neg_integer(),
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
  end

  @doc "Attaches one local or remote consumer process to an open generation."
  @spec attach(key(), generation(), pid()) :: {:ok, gap_summary()} | {:error, atom()}
  def attach(key, generation, consumer \\ self()) do
    with_connection(key, &Connection.attach(&1, generation, consumer))
  end

  @doc "Detaches the matching consumer without closing the upstream socket."
  @spec detach(key(), generation(), pid()) :: :ok | {:error, atom()}
  def detach(key, generation, consumer \\ self()) do
    with_connection(key, &Connection.detach(&1, generation, consumer))
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
  @spec info(key()) :: {:ok, connection_info()} | {:error, :not_found}
  def info(key) do
    with_connection(key, &Connection.info/1)
  end

  @doc "Lists all currently open connections."
  @spec list() :: [connection_info()]
  def list do
    Manager.connections()
    |> Enum.flat_map(fn connection ->
      case safe_connection_call(fn -> Connection.info(connection) end) do
        {:ok, info} -> [info]
        {:error, :not_found} -> []
      end
    end)
    |> Enum.sort_by(&inspect(&1.key))
  end

  @doc "Returns bounded aggregate connection and discarded-traffic counters."
  @spec diagnostics() :: %{
          open_connections: non_neg_integer(),
          attached_connections: non_neg_integer(),
          detached_connections: non_neg_integer(),
          discarded_frames: non_neg_integer(),
          discarded_bytes: non_neg_integer()
        }
  def diagnostics do
    infos = list()

    Enum.reduce(
      infos,
      %{
        open_connections: length(infos),
        attached_connections: 0,
        detached_connections: 0,
        discarded_frames: 0,
        discarded_bytes: 0
      },
      fn info, totals ->
        totals
        |> Map.update!(
          if(info.attached?, do: :attached_connections, else: :detached_connections),
          &(&1 + 1)
        )
        |> Map.update!(:discarded_frames, &(&1 + info.discarded_frames))
        |> Map.update!(:discarded_bytes, &(&1 + info.discarded_bytes))
      end
    )
  end

  defp with_connection(key, callback) do
    case safe_manager_lookup(key) do
      {:ok, connection} -> safe_connection_call(fn -> callback.(connection) end)
      {:error, :not_found} = error -> error
    end
  end

  defp safe_manager_lookup(key) do
    Manager.lookup(key)
  catch
    :exit, _reason -> {:error, :not_found}
  end

  defp safe_connection_call(callback) do
    callback.()
  catch
    :exit, _reason -> {:error, :not_found}
  end
end
