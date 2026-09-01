defmodule TopicsClub.Irc.Session.CallRoutingTest do
  use ExUnit.Case, async: true

  alias TopicsClub.Irc.Session.CallRouting

  test "returns a disconnected error without mutating session state" do
    state = %{client: nil, client_info: nil}

    assert {:reply, {:error, :not_connected}, ^state} =
             CallRouting.handle(:connection_info, self(), state)
  end

  test "keeps the applied transport revision separate from a refreshed database row" do
    state = %{
      applied_transport_revision: 7,
      connection: %{transport_revision: 8}
    }

    assert {:reply, 7, ^state} =
             CallRouting.handle(:applied_transport_revision, self(), state)
  end
end
