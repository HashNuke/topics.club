defmodule TopicsClub.Irc.ChannelListPageTest do
  use ExUnit.Case, async: true

  alias TopicsClub.Irc.ChannelListPage

  test "returns fixed 25-channel pages and clamps an out-of-range page" do
    channels =
      Enum.map(1..53, fn index ->
        %{channel: "#channel-#{index}", users: 100 - index, topic: "Topic #{index}"}
      end)

    assert %{
             channels: first_page,
             page: 1,
             page_size: 25,
             total_channels: 53,
             total_pages: 3
           } = ChannelListPage.build(channels, "", 1)

    assert length(first_page) == 25
    assert hd(first_page).channel == "#channel-1"

    assert %{channels: last_page, page: 3} = ChannelListPage.build(channels, "", 99)
    assert Enum.map(last_page, & &1.channel) == ["#channel-51", "#channel-52", "#channel-53"]
  end

  test "searches channel names and topics before paginating" do
    channels = [
      %{channel: "#beam", users: 20, topic: "Erlang and Elixir"},
      %{channel: "#music", users: 10, topic: "Albums and instruments"},
      %{channel: "#elixir-help", users: 5, topic: "Questions"}
    ]

    assert %{
             channels: [%{channel: "#beam"}, %{channel: "#elixir-help"}],
             page: 1,
             query: "ELIXIR",
             total_channels: 2,
             total_pages: 1
           } = ChannelListPage.build(channels, "  ELIXIR  ", 2)
  end
end
