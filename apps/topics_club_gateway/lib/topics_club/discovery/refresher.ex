defmodule TopicsClub.Discovery.Refresher do
  use GenServer

  require Logger

  alias TopicsClub.Discovery
  alias TopicsClub.Discovery.{Netsplit, ServerChannelLister}

  @check_interval :timer.hours(1)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def run(now \\ DateTime.utc_now(:second), opts \\ []) do
    fetch_networks = Keyword.get(opts, :fetch_networks, &Netsplit.fetch_networks/0)
    list_channels = Keyword.get(opts, :list_channels, &ServerChannelLister.fetch/1)
    max_concurrency = Keyword.get(opts, :max_concurrency, 2)

    with :ok <- maybe_refresh_networks(now, fetch_networks) do
      now
      |> Discovery.networks_due_for_channel_refresh()
      |> refresh_channels(now, list_channels, max_concurrency)
    end
  end

  @impl true
  def init(opts) do
    state = %{
      enabled?:
        Keyword.get(
          opts,
          :enabled?,
          Application.get_env(:topics_club_gateway, :discovery_refresh_enabled, false)
        ),
      interval: Keyword.get(opts, :interval, @check_interval),
      refreshing?: false
    }

    if state.enabled?, do: send(self(), :refresh)
    {:ok, state}
  end

  @impl true
  def handle_info(:refresh, %{refreshing?: false} = state) do
    owner = self()

    Task.start(fn ->
      result = run()
      send(owner, {:refresh_complete, result})
    end)

    {:noreply, %{state | refreshing?: true}}
  end

  def handle_info(:refresh, state), do: {:noreply, state}

  def handle_info({:refresh_complete, result}, state) do
    if result != :ok, do: Logger.warning("IRC discovery refresh failed: #{inspect(result)}")
    Process.send_after(self(), :refresh, state.interval)
    {:noreply, %{state | refreshing?: false}}
  end

  defp maybe_refresh_networks(now, fetch_networks) do
    if Discovery.network_catalog_due?(now) do
      with {:ok, networks} <- fetch_networks.(),
           {:ok, _networks} <- Discovery.sync_networks(networks, now) do
        :ok
      end
    else
      :ok
    end
  end

  defp refresh_channels(networks, now, list_channels, 1) do
    Enum.each(networks, &refresh_channel_list(&1, now, list_channels))
    :ok
  end

  defp refresh_channels(networks, now, list_channels, max_concurrency) do
    networks
    |> Task.async_stream(
      &refresh_channel_list(&1, now, list_channels),
      max_concurrency: max_concurrency,
      timeout: :infinity
    )
    |> Stream.run()

    :ok
  end

  defp refresh_channel_list(network, now, list_channels) do
    try do
      case list_channels.(network) do
        {:ok, channels} -> Discovery.replace_server_channels(network, channels, now)
        {:error, reason} -> Discovery.mark_channel_refresh_error(network, reason)
      end
    rescue
      exception ->
        Logger.warning(
          "IRC discovery refresh failed for #{network.name}: #{Exception.message(exception)}"
        )

        Discovery.mark_channel_refresh_error(network, Exception.message(exception))
    end
  end
end
