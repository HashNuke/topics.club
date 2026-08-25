defmodule Ircpipe.Irc.CommandRegistryTest do
  use ExUnit.Case, async: true

  alias Ircpipe.Irc.CommandRegistry

  test "preserves IRC trailing parameters and classifies enabled queries" do
    assert {:ok, intent} =
             CommandRegistry.resolve("WHOIS mira", %{isupport: %{}})

    assert intent.message.command == "WHOIS"
    assert intent.message.params == ["mira"]
    assert intent.disposition == :query

    assert {:ok, message_intent} =
             CommandRegistry.resolve("PRIVMSG mira :hello from topics.club", %{isupport: %{}})

    assert message_intent.message.params == ["mira", "hello from topics.club"]
    assert message_intent.disposition == :managed
  end

  test "rejects protocol-owned, operator, unknown, and malformed commands with typed errors" do
    assert {:error, %{code: "protocol_owned"}} =
             CommandRegistry.resolve("PING server", %{isupport: %{}})

    assert {:error, %{code: "operator_only"}} =
             CommandRegistry.resolve("OPER root secret", %{isupport: %{}})

    assert {:error, %{code: "unknown_command"}} =
             CommandRegistry.resolve("MADEUP value", %{isupport: %{}})

    assert {:error, %{code: "invalid_raw_command"}} =
             CommandRegistry.resolve("PRIVMSG mira :hello\nQUIT", %{isupport: %{}})
  end

  test "validates application arity and redacts sensitive parameters" do
    assert {:error, %{code: "invalid_arguments", usage: usage}} =
             CommandRegistry.resolve("PRIVMSG mira", %{isupport: %{}})

    assert usage =~ "PRIVMSG"

    assert {:ok, intent} =
             CommandRegistry.resolve("JOIN #private swordfish", %{isupport: %{}})

    assert intent.display == "JOIN #private [redacted]"
    assert intent.message.params == ["#private", "swordfish"]

    assert {:error, %{code: "not_yet_managed"}} =
             CommandRegistry.resolve("JOIN 0", %{isupport: %{}})

    assert {:error, %{code: "not_yet_managed"}} =
             CommandRegistry.resolve("JOIN #one,#two", %{isupport: %{}})

    assert {:error, %{code: "not_yet_managed"}} =
             CommandRegistry.resolve("PART #one,#two", %{isupport: %{}})

    assert {:error, %{code: "invalid_arguments"}} =
             CommandRegistry.resolve("USERS one two", %{isupport: %{}})
  end

  test "blocks retained service credentials, DCC, and other unsupported CTCP commands" do
    assert {:error, %{code: "credential_bearing"}} =
             CommandRegistry.resolve(
               "PRIVMSG NickServ :IDENTIFY hunter2",
               %{isupport: %{}}
             )

    assert {:error, %{code: "unsupported_ctcp"}} =
             CommandRegistry.resolve(
               "PRIVMSG mira :\x01DCC SEND secret.txt 127001 1234 99\x01",
               %{isupport: %{}}
             )

    assert {:error, %{code: "unsupported_ctcp"}} =
             CommandRegistry.resolve("PRIVMSG mira :hello \x01VERSION\x01", %{isupport: %{}})

    assert {:error, %{code: "unsupported_ctcp"}} =
             CommandRegistry.resolve(
               "PRIVMSG #elixir :\x01ACTION waves\x01VERSION\x01",
               %{isupport: %{}}
             )

    assert {:ok, %{disposition: :managed}} =
             CommandRegistry.resolve("PRIVMSG #elixir :\x01ACTION waves\x01", %{isupport: %{}})
  end
end
