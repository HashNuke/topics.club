defmodule Ircpipe.Discovery.NetsplitTest do
  use ExUnit.Case, async: true

  alias Ircpipe.Discovery.Netsplit

  test "parses ranked networks without using Netsplit channel data" do
    html = """
    <tr><td>1.</td><td>1.</td><td></td><td><a href="/networks/Libera.Chat/">Libera.Chat</a></td><td>29264</td><td>21365</td><td>28</td></tr>
    <tr><td>2.</td><td>2.</td><td></td><td><a href="/networks/OFTC/">OFTC</a></td><td>13128</td><td>3906</td><td>17</td></tr>
    <tr><td>3.</td><td>3.</td><td></td><td><a href="/networks/Rizon/">Rizon</a></td><td>9407</td><td>6624</td><td>18</td></tr>
    """

    assert Netsplit.parse_top_networks(html, 2) == [
             %{
               name: "Libera.Chat",
               rank: 1,
               slug: "Libera.Chat",
               source_url: "https://netsplit.de/networks/Libera.Chat/"
             },
             %{
               name: "OFTC",
               rank: 2,
               slug: "OFTC",
               source_url: "https://netsplit.de/networks/OFTC/"
             }
           ]
  end

  test "prefers the secure main-server connection endpoint" do
    html = """
    <tr><td>irc.libera.chat</td><td>6667</td><td>off</td><td>yes</td></tr>
    <tr><td>irc.libera.chat</td><td>6697</td><td>on</td><td>yes</td></tr>
    """

    assert Netsplit.parse_connection(html) ==
             {:ok, %{host: "irc.libera.chat", port: 6697, use_tls: true}}
  end

  test "falls back to an available non-TLS main server" do
    html = "<tr><td>irc.example.test</td><td>6667</td><td>off</td><td>yes</td></tr>"

    assert Netsplit.parse_connection(html) ==
             {:ok, %{host: "irc.example.test", port: 6667, use_tls: false}}
  end
end
