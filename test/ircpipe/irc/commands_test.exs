defmodule Ircpipe.Irc.CommandsTest do
  use ExUnit.Case, async: true

  alias Ircpipe.Irc.Commands

  test "suggests commands from a slash prefix" do
    assert [%{name: "/join"}] = Commands.suggest("/jo")
  end

  test "does not suggest commands for normal chat messages" do
    assert Commands.suggest("hello /join") == []
  end

  test "parses slash commands on the backend" do
    assert {:ok, %{name: "join", args: ["#elixir"]}} = Commands.parse("/join #elixir")

    assert {:ok, %{name: "msg", args: ["NickServ", "help"]}} =
             Commands.parse("/msg NickServ help")

    assert {:ok, %{name: "me", args: ["waves hello"]}} = Commands.parse("/me waves hello")
  end

  test "rejects normal messages and unknown slash commands" do
    assert {:error, :not_a_command} = Commands.parse("hello")
    assert {:error, {:unknown_command, "wat"}} = Commands.parse("/wat")
  end
end
