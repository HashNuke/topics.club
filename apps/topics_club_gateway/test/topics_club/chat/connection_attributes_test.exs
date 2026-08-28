defmodule TopicsClub.Chat.ConnectionAttributesTest do
  use ExUnit.Case, async: true

  alias TopicsClub.Accounts.User
  alias TopicsClub.Chat.ConnectionAttributes

  test "prepares string-keyed attributes with a canonical host and safe user nickname" do
    user = %User{email: "3.Dev+chat@example.com"}

    assert ConnectionAttributes.prepare(%{"host" => "  IRC.Example.COM  "}, user) == %{
             "host" => "irc.example.com",
             "nickname" => "u_3_Dev_chat"
           }
  end

  test "prepares atom-keyed attributes and defaults SASL username to the nickname" do
    user = %User{email: "mira@example.com"}

    assert ConnectionAttributes.prepare(
             %{host: " IRC.Example.COM ", nickname: "mira_", sasl_password: "secret"},
             user
           ) == %{
             host: "irc.example.com",
             nickname: "mira_",
             sasl_password: "secret",
             sasl_username: "mira_"
           }
  end

  test "preserves an explicit SASL username and ignores blank optional values" do
    user = %User{email: "mira@example.com"}

    attrs = %{
      "host" => "irc.example.com",
      "nickname" => "  mira  ",
      "sasl_password" => "  secret  ",
      "sasl_username" => " account "
    }

    assert ConnectionAttributes.prepare(attrs, user) == %{attrs | "nickname" => "mira"}

    assert ConnectionAttributes.prepare(
             %{"host" => "irc.example.com", "nickname" => " ", "sasl_password" => " "},
             user
           ) == %{
             "host" => "irc.example.com",
             "nickname" => "mira",
             "sasl_password" => " "
           }
  end

  test "leaves a non-binary host unchanged" do
    user = %User{email: "mira@example.com"}

    assert ConnectionAttributes.prepare(%{host: nil}, user) == %{host: nil, nickname: "mira"}
  end

  test "builds bounded IRC-safe nicknames from unusual email local parts" do
    assert ConnectionAttributes.default_nick(%User{email: "---@example.com"}) == "u_---"
    assert ConnectionAttributes.default_nick(%User{email: "@example.com"}) == "topics_user"
    assert ConnectionAttributes.default_nick(%User{email: "9lives@example.com"}) == "u_9lives"

    nick =
      ConnectionAttributes.default_nick(%User{
        email: "abcdefghijklmnopqrstuvwxyz@example.com"
      })

    assert nick == "abcdefghijklmnopqrstuvwx"
    assert String.length(nick) == 24
  end

  test "normalizes an endpoint host value" do
    assert ConnectionAttributes.normalize_host_value(" IRC.Example.COM ") == "irc.example.com"
  end
end
