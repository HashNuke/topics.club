defmodule TopicsClub.Irc.Session.ClientOptionsTest do
  use ExUnit.Case, async: true

  alias TopicsClub.Chat.ServerConnection
  alias TopicsClub.Irc.Session.ClientOptions

  test "builds envelope client options with identity fallbacks and required capabilities" do
    connection = %ServerConnection{
      host: "irc.example.test",
      port: 6697,
      use_tls: true,
      nickname: "mira"
    }

    opts = ClientOptions.build(connection, self())

    assert opts[:host] == "irc.example.test"
    assert opts[:port] == 6697
    assert opts[:tls]
    assert opts[:nick] == "mira"
    assert opts[:username] == "mira"
    assert opts[:realname] == "mira"
    assert opts[:reconnect] == [max_attempts: :infinity, delay: 5_000]
    assert opts[:events] == :envelope
    assert opts[:notify] == self()

    assert opts[:caps] == [
             "server-time",
             "echo-message",
             "multi-prefix",
             "userhost-in-names",
             "message-tags",
             "batch",
             "labeled-response"
           ]

    refute Keyword.has_key?(opts, :password)
    refute Keyword.has_key?(opts, :sasl)
  end

  test "adds server password and only complete SASL credentials" do
    connection = %ServerConnection{
      host: "irc.example.test",
      port: 6667,
      use_tls: false,
      nickname: "mira",
      username: "ident",
      realname: "Mira Example",
      server_password: "server-secret",
      sasl_username: "account",
      sasl_password: "account-secret"
    }

    opts = ClientOptions.build(connection, self())

    assert opts[:username] == "ident"
    assert opts[:realname] == "Mira Example"
    assert opts[:password] == "server-secret"
    assert opts[:sasl] == {:plain, "account", "account-secret"}

    incomplete = ClientOptions.build(%{connection | sasl_password: ""}, self())
    refute Keyword.has_key?(incomplete, :sasl)

    incomplete = ClientOptions.build(%{connection | sasl_username: ""}, self())
    refute Keyword.has_key?(incomplete, :sasl)
  end

  test "preserves blank identity fields while omitting a blank server password" do
    connection = %ServerConnection{
      host: "irc.example.test",
      port: 6697,
      use_tls: true,
      nickname: "mira",
      username: "",
      realname: "",
      server_password: ""
    }

    opts = ClientOptions.build(connection, self())

    assert opts[:username] == ""
    assert opts[:realname] == ""
    refute Keyword.has_key?(opts, :password)
  end
end
