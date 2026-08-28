defmodule Ircpipe.Irc.Session.CallRoutingTest do
  use ExUnit.Case, async: true

  alias Ircpipe.Irc.Session.CallRouting

  test "returns a disconnected error without mutating session state" do
    state = %{client: nil, client_info: nil}

    assert {:reply, {:error, :not_connected}, ^state} =
             CallRouting.handle(:connection_info, self(), state)
  end
end
