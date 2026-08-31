defmodule TopicsClub.Discovery do
  import Ecto.Query

  alias TopicsClub.Discovery.{Network, ServerChannel}
  alias TopicsClub.Repo

  @channel_refresh_seconds :timer.hours(24) |> div(1_000)
  @network_refresh_seconds :timer.hours(24 * 7) |> div(1_000)
  @featured_channel_names ~w(#ruby #python #linux #rust #javascript #ubuntu)
  @server_channel_page_size 25

  def sync_networks(entries, refreshed_at) when is_list(entries) do
    Repo.transaction(fn ->
      slugs = Enum.map(entries, &Map.fetch!(&1, :slug))

      from(network in Network, where: network.active and network.slug not in ^slugs)
      |> Repo.update_all(set: [active: false, updated_at: refreshed_at])

      Enum.map(entries, fn attrs ->
        attrs = Map.merge(attrs, %{active: true, source_refreshed_at: refreshed_at})

        %Network{}
        |> Network.changeset(attrs)
        |> Repo.insert!(
          conflict_target: :slug,
          on_conflict:
            {:replace,
             [
               :name,
               :host,
               :port,
               :use_tls,
               :rank,
               :source_url,
               :source_refreshed_at,
               :active,
               :updated_at
             ]},
          returning: true
        )
      end)
    end)
  end

  def replace_server_channels(%Network{} = network, channels, listed_at) when is_list(channels) do
    Repo.transaction(fn ->
      from(server_channel in ServerChannel,
        where: server_channel.irc_network_id == ^network.id
      )
      |> Repo.delete_all()

      now = DateTime.utc_now(:second)

      rows =
        channels
        |> Enum.map(fn channel ->
          %{
            irc_network_id: network.id,
            name: channel |> Map.fetch!(:name) |> sanitize_irc_text(),
            topic: channel |> Map.get(:topic) |> sanitize_irc_text(),
            user_count: Map.get(channel, :user_count, 0),
            listed_at: listed_at,
            inserted_at: now,
            updated_at: now
          }
        end)
        |> Enum.uniq_by(& &1.name)

      {_count, _rows} = Repo.insert_all(ServerChannel, rows)

      network
      |> Ecto.Changeset.change(channels_refreshed_at: listed_at, last_refresh_error: nil)
      |> Repo.update!()

      length(rows)
    end)
  end

  def list_popular_server_channels(opts \\ []) do
    limit = Keyword.get(opts, :limit)

    ServerChannel
    |> active_server_channels_query()
    |> order_by([server_channel, network],
      desc: server_channel.user_count,
      asc: network.rank,
      asc: server_channel.name
    )
    |> maybe_limit(limit)
    |> Repo.all()
  end

  def paginate_server_channels(opts \\ []) do
    requested_page = Keyword.get(opts, :page, 1)
    page = if is_integer(requested_page) and requested_page > 0, do: requested_page, else: 1
    search = opts |> Keyword.get(:search, "") |> normalize_search()

    query =
      ServerChannel
      |> active_server_channels_query()
      |> maybe_filter_server(Keyword.get(opts, :server))
      |> maybe_search(search)

    total_channels =
      query
      |> exclude(:preload)
      |> Repo.aggregate(:count, :id)

    total_pages =
      max(div(total_channels + @server_channel_page_size - 1, @server_channel_page_size), 1)

    page = min(page, total_pages)

    server_channels =
      query
      |> order_by([server_channel, network],
        desc: server_channel.user_count,
        asc: network.rank,
        asc: server_channel.name
      )
      |> limit(^@server_channel_page_size)
      |> offset(^((page - 1) * @server_channel_page_size))
      |> Repo.all()

    %{
      page: page,
      page_size: @server_channel_page_size,
      query: search,
      server_channels: server_channels,
      total_channels: total_channels,
      total_pages: total_pages
    }
  end

  def list_featured_server_channels(limit \\ 6) when is_integer(limit) and limit > 0 do
    candidates =
      ServerChannel
      |> active_server_channels_query()
      |> where(
        [server_channel, _network],
        fragment("lower(?)", server_channel.name) in ^@featured_channel_names
      )
      |> order_by([server_channel, network],
        desc: server_channel.user_count,
        asc: network.rank
      )
      |> Repo.all()

    featured =
      Enum.flat_map(@featured_channel_names, fn name ->
        case Enum.find(candidates, &(String.downcase(&1.name) == name)) do
          nil -> []
          channel -> [channel]
        end
      end)

    selected_names = MapSet.new(featured, &String.downcase(&1.name))

    fallback =
      list_popular_server_channels(limit: limit * 4)
      |> Enum.reject(&MapSet.member?(selected_names, String.downcase(&1.name)))
      |> Enum.uniq_by(&String.downcase(&1.name))

    Enum.take(featured ++ fallback, limit)
  end

  def get_server_channel!(id) do
    ServerChannel
    |> preload(:network)
    |> Repo.get!(id)
  end

  def list_active_networks do
    Network
    |> where([network], network.active)
    |> order_by([network], asc: network.rank)
    |> Repo.all()
  end

  def networks_due_for_channel_refresh(now) do
    cutoff = DateTime.add(now, -@channel_refresh_seconds, :second)

    Network
    |> where(
      [network],
      network.active and
        (is_nil(network.channels_refreshed_at) or network.channels_refreshed_at <= ^cutoff)
    )
    |> order_by([network], asc: network.rank)
    |> Repo.all()
  end

  def network_catalog_due?(now) do
    cutoff = DateTime.add(now, -@network_refresh_seconds, :second)

    not Repo.exists?(from(network in Network, where: network.active)) or
      Repo.exists?(
        from(network in Network,
          where: network.active and network.source_refreshed_at <= ^cutoff
        )
      )
  end

  def mark_channel_refresh_error(%Network{} = network, reason) do
    network
    |> Ecto.Changeset.change(last_refresh_error: inspect(reason))
    |> Repo.update()
  end

  defp active_server_channels_query(query) do
    query
    |> join(:inner, [server_channel], network in assoc(server_channel, :network))
    |> where([_server_channel, network], network.active)
    |> preload([_server_channel, network], network: network)
  end

  defp maybe_filter_server(query, nil), do: query

  defp maybe_filter_server(query, server) do
    where(
      query,
      [_server_channel, network],
      fragment("lower(?)", network.host) == ^String.downcase(server.host) and
        network.port == ^server.port and network.use_tls == ^server.use_tls
    )
  end

  defp maybe_search(query, ""), do: query

  defp maybe_search(query, search) do
    pattern = "%#{escape_like(search)}%"

    where(
      query,
      [server_channel, network],
      ilike(server_channel.name, ^pattern) or ilike(server_channel.topic, ^pattern) or
        ilike(network.name, ^pattern)
    )
  end

  defp normalize_search(search) when is_binary(search) do
    search
    |> String.trim()
    |> String.slice(0, 100)
  end

  defp normalize_search(_search), do: ""

  defp escape_like(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  defp maybe_limit(query, nil), do: query
  defp maybe_limit(query, limit), do: limit(query, ^limit)

  defp sanitize_irc_text(nil), do: nil
  defp sanitize_irc_text(value) when is_binary(value), do: String.replace_invalid(value, "�")
end
