defmodule TopicsClub.Irc.ChannelListPage do
  @moduledoc false

  @page_size 25
  @max_query_length 100

  def build(channels, query, requested_page) when is_list(channels) do
    query = normalize_query(query)
    matching_channels = filter(channels, query)
    total_channels = length(matching_channels)
    total_pages = max(div(total_channels + @page_size - 1, @page_size), 1)
    page = requested_page |> normalize_page() |> min(total_pages)

    %{
      channels: Enum.slice(matching_channels, (page - 1) * @page_size, @page_size),
      page: page,
      page_size: @page_size,
      query: query,
      total_channels: total_channels,
      total_pages: total_pages
    }
  end

  defp filter(channels, ""), do: channels

  defp filter(channels, query) do
    normalized_query = String.downcase(query)

    Enum.filter(channels, fn channel ->
      searchable = "#{Map.get(channel, :channel, "")} #{Map.get(channel, :topic, "")}"
      String.contains?(String.downcase(searchable), normalized_query)
    end)
  end

  defp normalize_query(query) when is_binary(query) do
    query
    |> String.trim()
    |> String.slice(0, @max_query_length)
  end

  defp normalize_query(_query), do: ""

  defp normalize_page(page) when is_integer(page) and page > 0, do: page
  defp normalize_page(_page), do: 1
end
