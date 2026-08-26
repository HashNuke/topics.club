defmodule Ircpipe.Irc.SessionSupervisorTest do
  use ExUnit.Case, async: true

  alias Ircpipe.Chat.ServerConnection
  alias Ircpipe.Irc.SessionSupervisor

  test "stopping an already-closed IRC client succeeds" do
    unique_id = System.unique_integer([:positive])
    connection = %ServerConnection{id: unique_id, user_id: unique_id}

    start_supervised!({Ircpipe.ClosedIrcSession, connection})

    assert :ok = SessionSupervisor.stop_session(connection)
  end
end
