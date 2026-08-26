defmodule Ircpipe.Discovery.Netsplit do
  @base_url "https://netsplit.de"

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

  defp clean_text(value) do
    value
    |> String.replace(~r/<[^>]+>/, "")
    |> String.replace("&amp;", "&")
    |> String.replace("&nbsp;", " ")
    |> String.trim()
  end
end
