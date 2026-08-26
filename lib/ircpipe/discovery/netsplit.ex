defmodule Ircpipe.Discovery.Netsplit do
  require Logger

  @base_url "https://netsplit.de"
  @top_networks_url "#{@base_url}/networks/top100.php"

  def fetch_networks(opts \\ []) do
    limit = Keyword.get(opts, :limit, 30)
    get = Keyword.get(opts, :get, &get/1)

    with {:ok, html} <- get.(@top_networks_url),
         networks when networks != [] <- parse_top_networks(html, 100) do
      fetch_available_connections(networks, get, limit)
    else
      [] -> {:error, :networks_not_found}
      error -> error
    end
  end

  defp fetch_available_connections(networks, get, limit) do
    networks
    |> Task.async_stream(
      fn network -> fetch_connection(network, get) end,
      max_concurrency: 4,
      ordered: true,
      timeout: :infinity
    )
    |> Stream.flat_map(fn
      {:ok, {:ok, network}} ->
        [network]

      {:ok, {:error, reason}} ->
        Logger.warning("Skipping Netsplit network without connection data: #{inspect(reason)}")
        []

      {:exit, reason} ->
        Logger.warning("Skipping failed Netsplit network task: #{inspect(reason)}")
        []
    end)
    |> Enum.take(limit)
    |> case do
      [] -> {:error, :connections_not_found}
      networks -> {:ok, networks}
    end
  end

  def parse_top_networks(html, limit \\ 30) when is_binary(html) do
    case Floki.parse_document(html) do
      {:ok, document} ->
        document
        |> Floki.find("tr")
        |> Enum.flat_map(&parse_network_row/1)
        |> Enum.take(limit)

      {:error, _reason} ->
        []
    end
  end

  def parse_connection(html) when is_binary(html) do
    rows =
      case Floki.parse_document(html) do
        {:ok, document} ->
          document
          |> Floki.find("tr")
          |> Enum.flat_map(&parse_connection_row/1)

        {:error, _reason} ->
          []
      end

    connection =
      Enum.find(rows, &(&1.main? and &1.use_tls)) ||
        Enum.find(rows, & &1.main?) ||
        Enum.find(rows, & &1.use_tls) ||
        List.first(rows)

    case connection do
      nil -> {:error, :connection_not_found}
      connection -> {:ok, Map.drop(connection, [:main?])}
    end
  end

  defp parse_network_row(row) do
    rank =
      row
      |> Floki.find("td")
      |> List.first()
      |> node_text()
      |> Integer.parse()

    link =
      row
      |> Floki.find("a")
      |> Enum.find(fn link ->
        link
        |> Floki.attribute("href")
        |> Enum.any?(&String.starts_with?(&1, "/networks/"))
      end)

    with {rank, _suffix} <- rank,
         link when not is_nil(link) <- link,
         [href | _rest] <- Floki.attribute(link, "href"),
         [slug] <-
           href
           |> String.trim_leading("/networks/")
           |> String.split("/", trim: true) do
      [
        %{
          name: link |> Floki.text() |> clean_text(),
          rank: rank,
          slug: slug,
          source_url: "#{@base_url}/networks/#{slug}/"
        }
      ]
    else
      _invalid_row -> []
    end
  end

  defp parse_connection_row(row) do
    cells = row |> Floki.find("td") |> Enum.map(&(Floki.text(&1) |> clean_text()))

    with [host, port, tls, main | _rest] <- cells,
         {port, ""} <- Integer.parse(port),
         tls <- String.downcase(tls),
         true <- tls in ["on", "off"],
         main <- String.downcase(main),
         true <- main in ["yes", "no"] do
      [%{host: host, port: port, use_tls: tls == "on", main?: main == "yes"}]
    else
      _invalid_row -> []
    end
  end

  defp node_text(nil), do: ""
  defp node_text(node), do: node |> Floki.text() |> clean_text()

  defp fetch_connection(network, get) do
    url = "#{@base_url}/servers/?net=#{URI.encode_www_form(network.slug)}"

    with {:ok, html} <- get.(url),
         {:ok, connection} <- parse_connection(html) do
      {:ok, Map.merge(network, connection)}
    else
      {:error, reason} -> {:error, {network.slug, reason}}
    end
  end

  defp get(url) do
    case Req.get(url, receive_timeout: 15_000, retry: :transient) do
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) -> {:ok, body}
      {:ok, %Req.Response{status: status}} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp clean_text(value) do
    value
    |> String.replace("&amp;", "&")
    |> String.replace("&nbsp;", " ")
    |> String.trim()
  end
end
