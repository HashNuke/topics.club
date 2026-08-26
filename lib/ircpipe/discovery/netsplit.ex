defmodule Ircpipe.Discovery.Netsplit do
  @base_url "https://netsplit.de"
  @top_networks_url "#{@base_url}/networks/top100.php"

  def fetch_networks(opts \\ []) do
    limit = Keyword.get(opts, :limit, 30)
    get = Keyword.get(opts, :get, &get/1)

    with {:ok, html} <- get.(@top_networks_url),
         networks when networks != [] <- parse_top_networks(html, limit) do
      networks
      |> Task.async_stream(
        fn network -> fetch_connection(network, get) end,
        max_concurrency: 4,
        ordered: true,
        timeout: :infinity
      )
      |> Enum.reduce_while({:ok, []}, fn
        {:ok, {:ok, network}}, {:ok, networks} ->
          {:cont, {:ok, [network | networks]}}

        {:ok, {:error, reason}}, _result ->
          {:halt, {:error, reason}}

        {:exit, reason}, _result ->
          {:halt, {:error, reason}}
      end)
      |> case do
        {:ok, networks} -> {:ok, Enum.reverse(networks)}
        error -> error
      end
    else
      [] -> {:error, :networks_not_found}
      error -> error
    end
  end

  def parse_top_networks(html, limit \\ 30) when is_binary(html) do
    ~r/<tr[^>]*>\s*<td[^>]*>\s*(\d+)\.\s*<\/td>.*?<a\s+href=["']\/networks\/([^\/'"]+)\/["'][^>]*>(.*?)<\/a>/si
    |> Regex.scan(html, capture: :all_but_first)
    |> Enum.map(fn [rank, slug, name] ->
      %{
        name: clean_text(name),
        rank: String.to_integer(rank),
        slug: slug,
        source_url: "#{@base_url}/networks/#{slug}/"
      }
    end)
    |> Enum.take(limit)
  end

  def parse_connection(html) when is_binary(html) do
    rows =
      ~r/<tr[^>]*>\s*<td[^>]*>([^<]+)<\/td>\s*<td[^>]*>(\d+)<\/td>\s*<td[^>]*>(on|off)<\/td>\s*<td[^>]*>(yes|no)<\/td>\s*<\/tr>/si
      |> Regex.scan(html, capture: :all_but_first)
      |> Enum.map(fn [host, port, tls, main] ->
        %{
          host: clean_text(host),
          port: String.to_integer(port),
          use_tls: String.downcase(tls) == "on",
          main?: String.downcase(main) == "yes"
        }
      end)

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
    |> String.replace(~r/<[^>]+>/, "")
    |> String.replace("&amp;", "&")
    |> String.replace("&nbsp;", " ")
    |> String.trim()
  end
end
