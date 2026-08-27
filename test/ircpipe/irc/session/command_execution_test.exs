defmodule Ircpipe.Irc.Session.CommandExecutionTest do
  use ExUnit.Case, async: true

  alias Ircpipe.Irc.Session.CommandExecution

  test "validates managed command targets against joined and pending state" do
    state = %{
      joined_channels: MapSet.new(["#joined"]),
      pending_joins: MapSet.new(["#pending"]),
      active_casemapping: :ascii
    }

    assert :ok =
             CommandExecution.prepare(state, %{
               disposition: :managed,
               message: %{command: "PRIVMSG", params: ["#joined", "hello"]}
             })

    assert {:error, :not_joined} =
             CommandExecution.prepare(state, %{
               disposition: :managed,
               message: %{command: "PRIVMSG", params: ["#missing", "hello"]}
             })

    assert {:error, :already_pending} =
             CommandExecution.prepare(state, %{
               disposition: :managed,
               message: %{command: "JOIN", params: ["#pending"]}
             })
  end
end
